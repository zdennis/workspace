require "securerandom"

module Workspace
  # The engine's check of a step's `require:` list: built-in proofs about the
  # repository and the run's files, run when an attempt's turn ends, after
  # `produces` and before `status:`. Each proof is a single-key mapping of the
  # step's definition (`{"commits" => 1}`) and the first that fails stops the
  # check. A proof that can't be read (no recorded starting commit, git not
  # answering, a file or plan that can't be read) fails as unproven: it never
  # passes. Nothing here raises.
  #
  # The proofs: `commits` (at least N commits since the attempt began, from the
  # attempt's `head.before`), `nonempty` (a file under the run's artifacts
  # directory is a non-empty regular file, not a link), `plan_status` (the
  # workspace plan's `status:` is the value) and `tracked_clean` (no tracked
  # file differs from HEAD and no rebase, merge, cherry-pick, revert or bisect is under way; submodules and
  # `assume-unchanged`/`skip-worktree` files are not seen). Git runs through {WorkflowGuard}, so it ignores
  # the user's and the system's config and every inherited `GIT_*` variable.
  #
  # Three more: `command` (the project's `commands.test` or `commands.lint` exits 0, run like a `status:` command
  # through {WorkflowCheck} in the checkout, 5 minutes at most), `inbox_item` (the workspace's own inbox holds an
  # item with the rendered dedupe key, in any state, updated since the attempt began) and `remote_unchanged` (the
  # branch on its remote is as it was when the attempt began, `attempt["remote"]`, which the engine reads after
  # {#remote_baseline?} says so, before the agent is typed to).
  #
  # `command` takes `optional: true` beside it: an unset command then passes, answered as `{"skipped" => record}` for the
  # engine to keep in the attempt's `proofs` and go on from the next entry (a set command is proved as usual).
  #
  # {OUTSIDE_LOCK} proofs are too slow for the run's lock, which {#check} is called under: it stops at one and
  # answers `{"outside" => pending}`, the engine runs {#run_outside} with the lock given up and comes back with
  # `from:` the next entry. Only a failure found before anything runs (the command isn't set, no recorded remote
  # state) is answered at once.
  class WorkflowRequire
    # The proofs a definition may name.
    PROOFS = %w[commits nonempty plan_status tracked_clean command inbox_item remote_unchanged exec].freeze

    # Seconds a `command` proof may run.
    COMMAND_TIMEOUT = 5 * 60

    # Each list an `exec` template may use: the name of the file it is written to, NUL after each path, in a private
    # directory made for the one run of the proof outside the checkout and removed when the program ends; and the
    # variable that names that file.
    EXEC_LISTS = {
      "changed.files" => ["changed-files", "WORKSPACE_CHANGED_FILES"],
      "run.changed.files" => ["run-changed-files", "WORKSPACE_RUN_CHANGED_FILES"],
      "changed.tests" => ["changed-tests", "WORKSPACE_CHANGED_TESTS"]
    }.freeze

    # The most seconds an `exec` proof's git reads take before its program starts: `git --version` once, then for each
    # of the two lists read through {WorkflowGuard#changed_paths} its filter config, diff and untracked files, then
    # the branch, each under {WorkflowGuard::GIT_TIMEOUT}. {.lost_after} adds it to the program's own limit.
    EXEC_SETUP_SECONDS = 8 * WorkflowGuard::GIT_TIMEOUT

    # The key of a pending proof that holds what {#run_outside} alone reads; the engine keeps it out of the attempt.
    FACTS_KEY = "facts"

    # The proofs {#run_outside} runs, outside the run's lock.
    OUTSIDE_LOCK = %w[command remote_unchanged exec].freeze

    # Why a remote has no reading, from {WorkflowGuard#remote_head}.
    UNREAD_TEXT = {
      "detached_head" => "HEAD was detached, so there was no branch to look at",
      "local_upstream" => "the branch tracks a local branch, so it has no remote to look at",
      "bad_remote" => "the branch's remote name looks like an option",
      "no_remote" => "the repository has no such remote (no origin, or the remote the branch names is gone)",
      "unreachable" => "git could not read it within #{WorkflowGuard::REMOTE_TIMEOUT} seconds; workspace reads it without your git config, " \
        "so it needs a non-interactive credential such as an ssh key in an agent, and a credential helper, insteadOf or core.sshCommand is not used"
    }.freeze

    # The placeholders an `inbox_item` key is rendered with (and `inputs.<name>`).
    KEY_VARIABLES = %w[run workspace].freeze

    # What an inbox dedupe key may hold (as in `Commands::Inbox`).
    KEY_PATTERN = /\A[A-Za-z0-9._:\/#@-]{1,200}\z/

    # @param guard [Workspace::WorkflowGuard] reads the checkout through hardened git calls
    # @param notes_dir_of [#call] given a workspace name, its notes directory, or nil when it can't be found
    # @param commands_config [Workspace::CommandsConfig, nil] the project's `commands.test` and `commands.lint` (`command` is unproven without it)
    # @param checker [Workspace::WorkflowCheck, nil] runs the `command` proof
    # @param inbox_for [#call, nil] given a workspace name, its inbox store (`inbox_item` is unproven without it)
    # @param tmpdir [#call] as `Dir.mktmpdir`: given a prefix, yields a new directory only this user can open and
    #   removes it afterwards; an `exec` proof's lists are written there
    def initialize(guard:, notes_dir_of:, commands_config: nil, checker: nil, inbox_for: nil, tmpdir: Dir.method(:mktmpdir))
      @guard = guard
      @tmpdir = tmpdir
      @notes_dir_of = notes_dir_of
      @commands_config = commands_config
      @checker = checker
      @inbox_for = inbox_for
    end

    # Seconds after a proof's start past which nothing will report it: its own limit, a minute, and for `exec`
    # the git reads made before its program starts.
    #
    # @param proof [Hash{String=>Object}] an attempt's open `proofs` record
    # @return [Numeric]
    def self.lost_after(proof)
      proof["timeout"] + 60 + ((proof["proof"] == "exec") ? EXEC_SETUP_SECONDS : 0)
    end

    # Whether an attempt of the step needs the remote read before its agent is told to start.
    #
    # @param step [Hash{String=>Object}] the step's definition
    # @return [Boolean]
    def self.remote_baseline?(step)
      Array(step["require"]).any? { |entry| entry.key?("remote_unchanged") }
    end

    # @param run [Hash{String=>Object}] a stored run
    # @param step [Hash{String=>Object}] the step's definition; a step without "require" passes
    # @param attempt [Hash{String=>Object}] the attempt that ended
    # @param from [Integer] the index of the `require` entry to start at
    # @return [Hash{String=>Object}, nil] nil when every proof passes; `{"skipped" => record}` for an optional `command` that is unset (go on from "index" + 1); `{"outside" => pending}` when the next proof
    #   is one to give to {#run_outside} (pending: "proof", "token" (this run of it), "index", "timeout", and "role", "command", "log",
    #   "before", or for `exec` "program", "log" and "facts", which is for {#run_outside} only and not to be kept); else "proof" (the name), "code" (`require_<name>`, or the proof's own such as
    #   `require_remote_unreachable`), "detail" (what was required and found), "unproven" (true when it could not be
    #   checked) and, for `commits`, "required", "found" and "base"; for `exec`, "program" (as written) and "log"
    def check(run:, step:, attempt:, from: 0)
      Array(step["require"]).each_with_index do |entry, index|
        next if index < from
        name, value = entry.first
        found = (name == "exec") ? exec_pending(entry, index, run, attempt) : prove(name, value, run, attempt, optional: entry["optional"] == true)
        next unless found
        return {"skipped" => found["skipped"].merge("index" => index)} if found["skipped"]
        return {"outside" => found["outside"].merge("index" => index)} if found["outside"]
        return {"proof" => name, "code" => "require_#{name}"}.merge(found)
      end
      nil
    rescue => e
      unknown(e)
    end

    # Runs one proof {#check} handed back. Called with the run's lock given up.
    #
    # @param pending [Hash{String=>Object}] {#check}'s "outside"
    # @param cwd [String] the run's checkout
    # @param env [Hash{String=>String, nil}] the `command`'s environment
    # @param stop_when [#call, nil] see {WorkflowCheck#call}; a `remote_unchanged` read is not stopped (15 seconds at most)
    # @return [Hash{String=>Object}] "record" (what to keep on the attempt) and "unmet" (nil, or a failure as {#check} answers)
    def run_outside(pending, cwd:, env: {}, stop_when: nil)
      record, unmet = case pending["proof"]
      when "command" then run_command(pending, cwd, env, stop_when)
      when "exec" then run_exec(pending, cwd, env, stop_when)
      else read_remote(pending["before"], cwd)
      end
      {"record" => record, "unmet" => unmet && {"proof" => pending["proof"], "code" => "require_#{pending["proof"]}"}.merge(unmet)}
    rescue => e
      {"record" => {"error" => "#{e.class}: #{e.message}"[0, 300]}, "unmet" => unknown(e)}
    end

    private

    def prove(name, value, run, attempt, optional: false)
      case name
      when "commits" then commits(value, run, attempt)
      when "nonempty" then nonempty(value, run)
      when "plan_status" then plan_status(value, run)
      when "tracked_clean" then tracked_clean(run)
      when "command" then command(value, run, attempt, optional)
      when "inbox_item" then inbox_item(value, run, attempt)
      when "remote_unchanged" then remote_unchanged(attempt)
      else unproven("unknown proof #{name.inspect}")
      end
    end

    def commits(required, run, attempt)
      base = attempt.dig("head", "before")
      short = base.to_s[0, 7]
      noun = "#{required} commit#{"s" unless required == 1}"
      return unproven("required #{noun}, but this attempt has no recorded starting commit") if base.nil?
      count = @guard.commits_since(run["worktree"], base)
      return unproven("required #{noun} since #{short}, but git could not count them") if count.nil?
      if count == :history_rewritten
        detail = "required #{noun} since #{short}, but #{short} is not an ancestor of HEAD, so history was rewritten"
        return unproven(detail).merge("reason" => "history_rewritten", "base" => base)
      end
      return nil if count >= required
      {"detail" => "required #{noun} since #{short}, found #{count}", "required" => required, "found" => count, "base" => base}
    end

    def nonempty(file, run)
      dir = run["artifacts_dir"]
      return unproven("required #{file} to be non-empty, but the run has no artifacts directory recorded") unless dir.is_a?(String) && !dir.empty?
      path = File.join(dir, file)
      result = WorkflowProduced.inspect_file(path, strict: true)
      return {"detail" => "required #{file} to be non-empty, found it missing"} unless result.exists
      return {"detail" => "required #{file} to be non-empty, found #{RULE_TEXT.fetch(result.rule, result.rule)}"} if result.rule
      return nil if inside?(File.realpath(path), File.realpath(dir))
      {"detail" => "required #{file} to be non-empty, found it outside the artifacts directory (through a linked directory)"}
    rescue SystemCallError
      unproven("required #{file} to be non-empty, but the file could not be read")
    end

    def inside?(real, real_dir)
      real.start_with?(real_dir.end_with?("/") ? real_dir : "#{real_dir}/")
    end

    RULE_TEXT = {"empty" => "it empty", "symlink" => "a symbolic link", "not_regular_file" => "something that is not a regular file"}.freeze
    private_constant :RULE_TEXT

    def plan_status(wanted, run)
      dir = @notes_dir_of.call(run["workspace"])
      return unproven("required plan status #{wanted}, but the workspace's notes directory could not be found") if dir.nil?
      plan = PlanFile.read(File.join(dir, PlanFile::FILE_NAME))
      return {"detail" => "required plan status #{wanted}, found no #{PlanFile::FILE_NAME}"} if plan.nil?
      return unproven("required plan status #{wanted}, but the plan could not be read") if plan.warnings.any? { |w| w["code"] == "unreadable" }
      written = plan.frontmatter["status"]
      unless PlanFile::STATUSES.include?(written)
        return unproven("required plan status #{wanted}, but the plan's status: is #{written.nil? ? "missing" : "not one of #{PlanFile::STATUSES.join(", ")}"}")
      end
      return nil if written == wanted
      {"detail" => "required plan status #{wanted}, found #{written}"}
    end

    def tracked_clean(run)
      paths = @guard.dirty_paths(run["worktree"], base: run)
      return unproven("required no changed tracked files, but git could not say") if paths.nil?
      return {"detail" => "required no changed tracked files, found a rebase, merge, cherry-pick, revert or bisect in progress (or git could not say)"} if @guard.operation_in_progress?(run["worktree"])
      return nil if paths.empty?
      {"detail" => "required no changed tracked files, found #{"at least " if paths.size >= WorkflowGuard::MAX_PATHS}#{paths.size} (#{paths.first(5).join(", ")})", "paths" => paths}
    end

    def command(role, run, attempt, optional = false)
      configured = @commands_config&.for_project(run["project"])&.[](role.to_s.to_sym)
      return {"skipped" => {"proof" => "command", "role" => role, "skipped" => "command_unset", "optional" => true}} if optional && !configured
      return unproven("required the project's #{role} command to exit 0, but #{@checker ? "it is not set" : "no checker is available"}") unless configured && @checker
      token = SecureRandom.hex(4)
      log = File.join(run["artifacts_dir"].to_s, "steps", "#{run["current"]}.#{attempt["n"]}.require-#{role}.#{token}.log")
      {"outside" => {"proof" => "command", "token" => token, "role" => role, "command" => configured, "log" => log, "timeout" => COMMAND_TIMEOUT}}
    end

    def run_command(pending, cwd, env, stop_when)
      role, log = pending.values_at("role", "log")
      result = @checker.call(command: pending["command"], cwd: cwd, timeout: pending["timeout"], log: log, env: env, stop_when: stop_when)
      record = {"exit_code" => result[:exit_code], "timed_out" => result[:timed_out], "error" => result[:error]}.compact
      return [record, nil] if result[:exit_code] == 0
      return [record, unproven("required the project's #{role} command to exit 0, but it ran past #{pending["timeout"]} seconds and was stopped (log #{log})").merge("log" => log)] if result[:timed_out]
      return [record, unproven("required the project's #{role} command to exit 0, but it #{result[:error] || "did not finish"}")] unless result[:exit_code]
      [record, {"detail" => "required the project's #{role} command to exit 0, found exit #{result[:exit_code]} (log #{log})", "exit_code" => result[:exit_code], "log" => log}]
    end

    # Under the lock: what can be refused before anything runs (no checker, a list whose starting commit is not
    # recorded, `{{changed.tests}}` with no `commands.test_files`), and the run's facts {#run_exec} needs, under
    # {FACTS_KEY} (the engine keeps that key out of the attempt's `proofs`).
    def exec_pending(entry, index, run, attempt)
      argv = entry["exec"]
      wanted = "required #{argv.first} to exit 0"
      return exec_unproven(argv, "#{wanted}, but no checker is available") unless @checker
      used = list_names(argv)
      head_before = present(attempt.dig("head", "before"))
      base_sha = present(run["base_sha"])
      (used & %w[changed.files changed.tests]).each do |name|
        return exec_unproven(argv, "#{wanted}, but its {{#{name}}} needs the commit this attempt began at, and this attempt has none recorded") unless head_before
      end
      if used.include?("run.changed.files") && !base_sha
        return exec_unproven(argv, "#{wanted}, but its {{run.changed.files}} needs the commit the run began at, and the run has none recorded")
      end
      globs, problem = test_globs(run["workspace"])
      if used.include?("changed.tests") && globs.empty?
        return exec_unproven(argv, "#{wanted}, but its {{changed.tests}} needs commands.test_files, which #{problem || "is not set for #{run["workspace"]}"}")
      end
      token = SecureRandom.hex(4)
      log = File.join(run["artifacts_dir"].to_s, "steps", "#{run["current"]}.#{attempt["n"]}.require-exec-#{index}.#{token}.log")
      scalars = {"checkout" => run["worktree"].to_s, "artifacts" => run["artifacts_dir"].to_s, "workspace" => run["workspace"].to_s,
                 "run" => run["id"].to_s, "run.base_sha" => base_sha.to_s, "attempt.head_before" => head_before.to_s}
        .merge(run["inputs"].to_h.to_h { |name, value| ["inputs.#{name}", value.to_s] })
      {"outside" => {"proof" => "exec", "token" => token, "program" => argv.first, "log" => log,
                     "timeout" => entry["timeout"] || WorkflowDefinition::EXEC_DEFAULT_TIMEOUT,
                     FACTS_KEY => {"argv" => argv, "head_before" => head_before, "base_sha" => base_sha,
                                   "base_guard" => run["base_guard"], "test_files" => globs, "scalars" => scalars}}}
    end

    # Outside the lock: lists the changed files, writes each list that could be read to its NUL file in a private
    # directory outside the checkout (never through a link the agent could plant), fills in the template and runs
    # it with no shell. Every list is read, not only those the template names, so a program can read one through
    # its variable instead of its arguments.
    def run_exec(pending, cwd, env, stop_when)
      facts = pending[FACTS_KEY]
      program, log = pending.values_at("program", "log")
      wanted = "required #{program} to exit 0"
      used = list_names(facts["argv"])
      lists = changed_lists(cwd, facts)
      missing = used - lists.keys
      return [{}, unproven("#{wanted}, but git could not list the files for {{#{missing.first}}}").merge("program" => program)] if missing.any?
      scalars = facts["scalars"]
      if facts["argv"].any? { |arg| arg.scan(WorkflowArgv::PLACEHOLDER).flatten.include?("branch") }
        branch = @guard.branch(cwd)
        return [{}, unproven("#{wanted}, but git could not say which branch is checked out").merge("program" => program)] if branch.nil?
        scalars = scalars.merge("branch" => branch)
      end
      argv = begin
        WorkflowArgv.render(facts["argv"], scalars: scalars, lists: lists)
      rescue ArgumentError => e
        return [{}, unproven("#{wanted}, but its program's path could not be expanded (#{e.message})").merge("program" => program)]
      end
      files = nil
      result = @tmpdir.call("workspace-exec") do |dir|
        files = write_lists(dir, lists)
        @checker.call(argv: argv, cwd: cwd, timeout: pending["timeout"], log: log, stop_when: stop_when,
          env: env.merge(EXEC_LISTS.values.to_h { |_, var| [var, nil] }, files.to_h { |name, path| [EXEC_LISTS.fetch(name)[1], path] }))
      end
      record = {"exit_code" => result[:exit_code], "timed_out" => result[:timed_out], "error" => result[:error]}.compact
      found = {"program" => program, "log" => log}
      return [record, nil] if result[:exit_code] == 0
      return [record, unproven("#{wanted}, but it ran past #{pending["timeout"]} seconds and was stopped (log #{log})").merge(found)] if result[:timed_out]
      return [record, unproven(too_long(wanted, used, files)).merge("program" => program)] if result[:error].to_s.include?("E2BIG")
      return [record, unproven("#{wanted}, but it #{result[:error] || "did not finish"}").merge("program" => program)] unless result[:exit_code]
      [record, {"detail" => "#{wanted}, found exit #{result[:exit_code]} (log #{log})", "exit_code" => result[:exit_code]}.merge(found)]
    rescue SystemCallError => e
      [{}, unproven("#{wanted}, but the changed-file lists could not be written (#{e.class})").merge("program" => program)]
    end

    # Every list whose starting commit is recorded and that git could read; one that can't be read is left out.
    def changed_lists(cwd, facts)
      head, base = facts.values_at("head_before", "base_sha")
      changed = head && @guard.changed_paths(cwd, base: head, base_guard: facts["base_guard"])
      run_changed = (base == head) ? changed : (base && @guard.changed_paths(cwd, base: base, base_guard: facts["base_guard"]))
      lists = {}
      lists["changed.files"] = changed if changed
      lists["run.changed.files"] = run_changed if run_changed
      lists["changed.tests"] = tests_among(changed, facts["test_files"]) if changed && facts["test_files"].any?
      lists
    end

    def tests_among(paths, globs)
      paths.select { |path| globs.any? { |glob| File.fnmatch(glob.b, path.b, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
    end

    # @return [Hash{String=>String}] the file each list was written to, NUL after each path
    def write_lists(dir, lists)
      lists.to_h do |name, paths|
        path = File.join(dir, EXEC_LISTS.fetch(name)[0])
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY, 0o600) do |io|
          io.write(paths.map { |each| each.b + "\0".b }.join.b)
        end
        [name, path]
      end
    end

    def too_long(wanted, used, files)
      text = "#{wanted}, but its arguments were too long for the system to start it (E2BIG)"
      named = used.select { |name| files.key?(name) }
      return text if named.empty?
      "#{text}; read #{named.map { |name| "{{#{name}}} from the file $#{EXEC_LISTS.fetch(name)[1]} names" }.join(", ")} instead of passing it as arguments"
    end

    def list_names(argv)
      WorkflowArgv.list_names(argv)
    end

    def test_globs(workspace)
      return [[], "can't be read here"] unless @commands_config
      [@commands_config.test_files(workspace), nil]
    rescue Workspace::Error => e
      [[], "could not be read (#{e.message[0, 200]})"]
    end

    def exec_unproven(argv, detail)
      unproven(detail).merge("program" => argv.first)
    end

    def present(sha)
      (sha.is_a?(String) && !sha.empty?) ? sha : nil
    end

    # `InboxStore` stamps `updated_at` in whole seconds, so the attempt's start is cut to seconds too.
    def inbox_item(template, run, attempt)
      return unproven("required an inbox item #{template}, but no inbox is available") unless @inbox_for
      key = WorkflowDefinition.render(template, {"run" => run["id"], "workspace" => run["workspace"]}.merge(run["inputs"].to_h.transform_keys { |name| "inputs.#{name}" }))
      return unproven("required an inbox item #{template}, but it renders to #{key.inspect[0, 80]}, which is not a valid dedupe key") unless key.match?(KEY_PATTERN)
      item = @inbox_for.call(run["workspace"]).list.find { |each| each["dedupe_key"] == key }
      wanted = "required an inbox item with dedupe key #{key} in workspace #{run["workspace"]}'s inbox"
      return {"detail" => "#{wanted}, found none (an item added with --project or --global is in another inbox and does not count)"} unless item
      return nil if updated_since?(item, attempt["started_at"])
      {"detail" => "#{wanted}, updated since this attempt began at #{attempt["started_at"]}, found one last updated at #{item["updated_at"].inspect} " \
        "(adding to a key whose item is done or dismissed changes nothing: pass --reopen)"}
    end

    def updated_since?(item, started_at)
      Time.iso8601(item["updated_at"].to_s).to_i >= Time.iso8601(started_at.to_s).to_i
    rescue ArgumentError
      false
    end

    def remote_unchanged(attempt)
      before = attempt["remote"]
      return unproven("required the remote branch to be unchanged, but this attempt recorded no remote state") unless before.is_a?(Hash)
      return unproven("required the remote branch to be unchanged, but it could not be read when this attempt began: #{unread_text(before["unread"])}") if before["unread"]
      {"outside" => {"proof" => "remote_unchanged", "token" => SecureRandom.hex(4), "before" => before, "timeout" => WorkflowGuard::REMOTE_READ_LIMIT}}
    end

    def read_remote(before, cwd)
      now = @guard.remote_head(cwd)
      wanted = "#{before["ref"]} on #{before["remote"]}"
      case now["unread"]
      when "unreachable"
        return [now, unproven("required #{wanted} to be unchanged, but #{unread_text("unreachable")}").merge("code" => "require_remote_unreachable")]
      when nil then nil
      else return [now, unproven("required #{wanted} to be unchanged, but now #{unread_text(now["unread"])}")]
      end
      unless now["remote"] == before["remote"] && now["ref"] == before["ref"]
        return [now, unproven("required #{wanted} to be unchanged, but the branch now tracks #{now["ref"]} on #{now["remote"]}")]
      end
      return [now, nil] if now["sha"] == before["sha"]
      [now, {"detail" => "required #{wanted} to stay at #{short_or_absent(before["sha"])}, found #{short_or_absent(now["sha"])}", "before" => before["sha"], "after" => now["sha"]}]
    end

    def short_or_absent(sha)
      sha ? sha[0, 7] : "(absent)"
    end

    def unread_text(reason)
      UNREAD_TEXT.fetch(reason, reason.to_s)
    end

    def unknown(error)
      {"proof" => "unknown", "code" => "require_unknown", "unproven" => true, "detail" => "a required proof could not be checked",
       "error" => "#{error.class}: #{error.message}"[0, 300]}
    end

    def unproven(detail)
      {"detail" => detail, "unproven" => true}
    end
  end
end
