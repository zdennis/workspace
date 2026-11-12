require "digest"
require "yaml"

module Workspace
  # `template adopt`: builds the render record (the sidecar) of a tmuxinator config written before records
  # existed, so `template status` and `template apply` can work on it.
  #
  # The inputs are read back out of the config: `name:` and `root:`, the banner text, the `Worktree — BRANCH
  # (PROJECT)` echo line of a worktree, a `pre_window: export WORKSPACE_TASK=` line, and the main agent through
  # {MainAgent}. The config is then rendered with the template a new one would use now and today's agent settings.
  # The record is `exact` when that render is byte for byte the file, and its `rendered_sha` is the file's.
  # Otherwise it is `approx`: the record is flagged `approx` and its `rendered_sha` is the render's, so the file
  # reads `modified` and `template apply` skips it (`skipped: approx`) unless `--force`.
  #
  # Each workspace is done inside its startup lock ({NameMigration#with_locks}, which waits; a dry run takes none)
  # and everything its row decides is read inside it, as {TemplateApply} does. Row outcomes: `adopted` (`would_adopt`
  # under a dry run) with `match` `exact` or `approx`, `skipped` (`tracked`: a usable record exists; `gone`) and
  # `failed` (`reason` and `code` the error code: `adopt_unrecoverable`, `workspace_locked`, a render error's).
  class TemplateAdopt
    # What was read back out of a config.
    #
    # @!attribute kind [Symbol] `:project` or `:worktree`
    # @!attribute inputs [Hash] render inputs by Symbol, with `agent_command` as the pane text the config holds
    Recovered = Data.define(:kind, :inputs)

    BANNER = /ascii-banner "([^"\n]*)"/
    ECHO = /Worktree — (.*) \(([^()\n]*)\)/
    TASK = /^pre_window: export WORKSPACE_TASK=(\S+)\s*$/
    HEADER = %r{\A# (/\S.*)$}
    private_constant :BANNER, :ECHO, :TASK, :HEADER

    # @param library [Workspace::Library] resolves the template a kind selects
    # @param project_config [Workspace::ProjectConfig] renders, finds a config and its agent pane text
    # @param writer [Workspace::TmuxinatorConfigWriter] reads and writes render records
    # @param main_agent [Workspace::MainAgent] says which agent a config's main pane runs
    # @param locks [Workspace::NameMigration] each workspace's startup lock
    def initialize(library:, project_config:, writer:, main_agent:, locks:)
      @library = library
      @project_config = project_config
      @writer = writer
      @main_agent = main_agent
      @locks = locks
    end

    # @param names [Array<String>] the workspaces, in order
    # @param dry_run [Boolean] decide every row, write nothing and take no lock
    # @return [Array<Hash>] one row per workspace: `workspace`, `outcome`, `reason`, `message`, `match`, `kind`,
    #   `template`, `code`
    def call(names, dry_run: false)
      names.map { |name| locked(name, dry_run) { one(name, dry_run) } }
    end

    # What adopting +name+ would take as its inputs, without writing anything.
    #
    # @param name [String] a workspace
    # @return [Recovered, nil] nil when it has no readable config or one this can't read the values from
    def recover(name)
      text = read(name)
      text && recover_from(name, text)
    rescue Error
      nil
    end

    private

    def locked(name, dry_run, &block)
      return yield if dry_run
      @locks.with_locks(name, &block)
    rescue NameMigration::LockUnavailable, Error => e
      failed(name, "workspace_locked", "can't take the workspace's startup lock: #{e.message}")
    end

    def one(name, dry_run)
      text = read(name)
      return row(name, "skipped", "gone", "its tmuxinator config is gone (renamed or removed while adopt waited)") unless text
      return row(name, "skipped", "tracked", "it already has a render record") if @writer.record(name)

      found = recover_from(name, text)
      chosen = @library.tmuxinator_template(found.kind, workspace: name)
      template_text = File.read(chosen["path"])
      inputs = TemplateStatus.record_inputs(record_for(found, chosen, template_text), @project_config)
      rendered = @project_config.render(found.kind, inputs, template_text)
      exact = rendered == text
      unless dry_run
        @writer.write_record_for(name, exact ? text : rendered, kind: found.kind, template: chosen["name"], template_sha: sha(template_text),
          inputs: found.inputs, approx: !exact)
      end
      message = exact ? "the render is the file" : "a render differs from the file, so it reads as edited and apply skips it unless --force"
      row(name, dry_run ? "would_adopt" : "adopted", nil, message, "match" => exact ? "exact" : "approx", "kind" => found.kind.to_s, "template" => chosen["name"])
    rescue Error => e
      failed(name, e.code, e.message)
    rescue SystemCallError, IOError => e
      failed(name, "error", e.message)
    end

    def record_for(found, chosen, template_text)
      TmuxinatorConfigWriter::Record.new(kind: found.kind, template: chosen["name"], template_sha: sha(template_text), inputs: found.inputs, rendered_sha: "")
    end

    def recover_from(name, text)
      data = begin
        YAML.safe_load(text)
      rescue Psych::Exception => e
        raise unrecoverable(name, "it is not valid YAML (#{e.message.lines.first.to_s.strip})")
      end
      raise unrecoverable(name, "it has no name: and root:") unless data.is_a?(Hash) && data["name"] && data["root"]

      session = data["name"].to_s
      root = data["root"].to_s
      config_path = text[HEADER, 1] || @project_config.config_path_for(name)
      agent_kind = @main_agent.kind(name)
      agent_kind = "claude" if agent_kind == "none"
      shared = {workspace_name: name, config_path: config_path, agent_kind: agent_kind,
                agent_command: @project_config.agent_pane_text(text, name)}
      if WorkspaceName.worktree?(name)
        branch, project = text.match(ECHO)&.captures
        project ||= WorkspaceName.project_of(name)
        branch ||= checkout_branch(root) || File.basename(root)
        raise unrecoverable(name, "its worktree branch is unknown") if branch.to_s.empty?
        display = text[BANNER, 1] || @project_config.banner_text("#{project}/#{File.basename(root)}")
        Recovered.new(kind: :worktree, inputs: shared.merge(tmux_session_name: session, worktree_path: root, project_name: project,
          worktree_branch: branch, display_name: display, task_id: text[TASK, 1]))
      else
        Recovered.new(kind: :project, inputs: shared.merge(project_name: session, project_root: root, display_name: text[BANNER, 1] || @project_config.banner_text(name)))
      end
    end

    # The branch a worktree checkout is on, from its `.git` file and the HEAD it points at; nil when unreadable or detached.
    def checkout_branch(root)
      link = File.read(File.join(root, ".git"))[/\Agitdir: (.+)$/, 1]
      return unless link
      File.read(File.expand_path("HEAD", File.expand_path(link, root)))[%r{\Aref: refs/heads/(.+)$}, 1]
    rescue SystemCallError, IOError
      nil
    end

    def unrecoverable(name, why)
      Error.new("Can't read the render inputs of #{name}'s tmuxinator config: #{why}.", code: "adopt_unrecoverable", details: {"name" => name})
    end

    def read(name)
      File.read(@project_config.config_path_for(name)) if @project_config.exists?(name)
    rescue SystemCallError, IOError
      nil
    end

    def row(name, outcome, reason, message, extra = {})
      {"workspace" => name, "outcome" => outcome, "reason" => reason, "message" => message, "match" => nil, "kind" => nil, "template" => nil,
       "code" => nil}.merge(extra)
    end

    def failed(name, code, message)
      row(name, "failed", code, message, "code" => code)
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end
