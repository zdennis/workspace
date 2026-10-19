require "json"
require "shellwords"

module Workspace
  module Commands
    # `spine start`: gets an agent working on one stage of a workspace's spine. The pane is the one
    # named, a new one (`--spawn`), the stage's owner when it is a live agent pane, or the main agent
    # pane; a workspace with no session is launched. In that order:
    #
    # 1. under the spine write lock, one write sets `status: in_progress`, `owner: <pane>`, `updated` and
    #    `updated_by` (the pane's agent label) and records `spine_changed`, so a refusal stops before
    #    anything is typed and the agent's first `spine show` already reads it as the owner;
    # 2. the brief is typed: the play's line, the `spine` pack, and a few lines that name the stage and
    #    its file (the title quoted, as data); no stage body is pasted;
    # 3. the pane is bound to the play with the `spine` pack and the stage as its focus, so the
    #    SessionStart hook repeats them after a `/clear`.
    #
    # Only a failed delivery leaves the file written without an agent; the result is then `failed`, and
    # its message says how to set the stage back.
    class SpineStart
      # Bumped whenever the `--json` document's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The agent kinds `--spawn` may start.
      AGENT_KINDS = PaneDispatch::AGENT_KINDS

      # The pack every brief carries.
      PACK = "spine"

      # Statuses that count as done, for the stage and for what it depends on.
      DONE = %w[completed skipped].freeze

      # The built-in play a stage gets by its `kind` when neither `--play` nor its file names one.
      KIND_PLAYS = {"research" => "research", "plan" => "implementation-plan", "implement" => "implementation-plan", "review" => "review"}.freeze

      # What `updated_by` says for a write made before the pane is known (a launch).
      LAUNCH_BY = "spine start"

      # @param stage [SpineTree::Stage]
      # @param dir [String] the `spine/` folder
      # @return [String] the lines that tell the agent which stage is its own
      # @param owned [Boolean] whether the file already names this pane as the owner (false for a launch, whose pane is written after)
      def self.brief(stage, dir, owned: true)
        "Work on stage #{stage.path} of this workspace's spine, titled #{JSON.generate(stage.title)}, and on nothing else. " \
          "Its file is #{JSON.generate(File.join(dir, stage.relative))}. Read #{JSON.generate(File.join(dir, "goal.md"))} and that file first: " \
          "the stage file is your brief, and its Done when says when you are finished. " \
          "The stage already reads in_progress#{" with this pane as its owner" if owned}; " \
          "keep it current with workspace spine set as the spine pack says. When you are done or blocked, set the stage's status and stop; " \
          "do not wait to be asked, the workspace tells the person when your turn ends. " \
          "If you reach the context threshold first, write your handoff doc and stop; the person's workspace app may ask for it." \
          "#{rework(stage)}"
      end

      # @return [String] a sentence about the failed check when the stage is being reworked, else empty
      def self.rework(stage)
        return "" unless stage.file&.check_failed?
        note = stage.file.value("check_note")
        " Its last check failed#{" (#{JSON.generate(note)})" if note}: fix what the check found before you complete it again."
      end

      # @param spine [Workspace::Commands::Spine] reads the stages and makes the locked write
      # @param panes [Workspace::PaneDispatch] reads, picks, spawns, types into and binds the panes
      # @param library [Workspace::Library] finds the play and words the prompt
      # @param composer [Workspace::InstructionComposer] composes the `spine` pack
      # @param notes [Workspace::Commands::Notes] names the workspace's checkout, where plays and packs are looked up
      # @param output [IO]
      def initialize(spine:, panes:, library:, composer:, notes:, output: $stdout)
        @spine = spine
        @panes = panes
        @library = library
        @composer = composer
        @notes = notes
        @output = output
      end

      # @param name [String] the workspace
      # @param path [String] the stage path, as `spine show` reports it
      # @param launch [#call] given the workspace, the play's ref (or nil) and the brief, launches the workspace
      #   and returns `{ok:, reason:, message:, pane:}` (the CLI supplies it, since launching is its job)
      # @param pane [String, nil] a pane id or `window.pane` of the workspace's session
      # @param spawn [String, nil] one of {AGENT_KINDS}: split a new pane and start that agent in it
      # @param play [String, nil] the play to send, in place of the file's `play:` and the kind's default
      # @param if_revision [String, nil] refuse with `stale_revision` unless the stage file's revision is this
      # @return [Hash] the document documented in docs/README.spine.md#spine-start: `outcome` `sent`, `spawned`,
      #   `launched`, `already_working` (nothing written) or `failed` (`reason` `prompt_not_sent` with nothing
      #   written, or the delivery's error code with the file left as written)
      # @raise [Workspace::Error] `no_spine`, `unknown_stage`, `spine_unwritable`, `stage_done`, `stage_waiting` (`details.reasons`: `check_pending` or `check_failed` per stage),
      #   `stale_revision`, `no_session`, `stage_owned`, `pane_busy`, `no_agent_pane`, `no_daemon`, the
      #   {Workspace::PaneLocator} codes, and the library's codes for a play that can't be read
      def start(name:, path:, launch:, pane: nil, spawn: nil, play: nil, if_revision: nil)
        raise ArgumentError, "give pane: or spawn:, not both" if pane && spawn
        raise ArgumentError, "unknown agent kind #{spawn.inspect}" if spawn && !AGENT_KINDS.include?(spawn)
        tree, stage = @spine.stage!(name, path)
        refuse(name, tree, stage, if_revision)
        cwd = @notes.checkout_root(name)
        entry = find_play(stage, play, cwd)
        live = @panes.session_live?(name)
        raise no_session(name) if live == false && (pane || spawn)
        return by_launch(name, stage, entry, self.class.brief(stage, tree.dir, owned: false), launch, if_revision) if live == false

        brief = self.class.brief(stage, tree.dir)

        body = @library.play_prompt(entry, brief, packs: @composer.compose(packs: [PACK], cwd: cwd)["text"])
        job = {name: name, stage: stage, play: entry, body: body, if_revision: if_revision}
        spawn ? by_spawn(job, spawn) : in_pane(job, pane)
      end

      private

      # The refusals the file alone decides; made again under the write lock.
      def refuse(name, tree, stage, if_revision)
        raise @spine.no_file(stage) unless stage.file
        if DONE.include?(stage.status) && !stage.file.check_failed?
          raise Workspace::Error.new("Stage #{stage.path} of '#{name}' is #{stage.status}, so there is nothing to start. " \
            "Reopen it with: workspace spine set #{name} #{stage.path} --status in_progress",
            code: "stage_done", details: {"workspace" => name, "path" => stage.path, "status" => stage.status})
        end
        waits = waits_on(tree, stage)
        if waits.any?
          reasons = waits.to_h { |id, sibling| [id, wait_reason(sibling)] }.compact
          note = reasons.empty? ? "" : " (#{reasons.map { |id, reason| "#{id}: #{reason}" }.join(", ")})"
          ids = waits.keys
          raise Workspace::Error.new("Stage #{stage.path} of '#{name}' depends on #{ids.join(", ")}, which #{(ids.size == 1) ? "is" : "are"} not completed or skipped#{note}.",
            code: "stage_waiting", details: {"workspace" => name, "path" => stage.path, "waits_on" => ids, "reasons" => reasons})
        end
        return if if_revision.nil? || if_revision.downcase == stage.file.revision
        raise Workspace::Error.new("#{stage.relative} changed: its revision is #{stage.file.revision}, not #{if_revision}.",
          code: "stale_revision", details: {"revision" => stage.file.revision, "status" => stage.status})
      end

      # The ids in `depends_on` whose sibling is not done by its file (a folder-only sibling by its sub-stages),
      # with the sibling. A completed claim whose check has no passing verdict is not done. A repeated id means
      # the first stage with it.
      def waits_on(tree, stage)
        parent = stage.path.include?("/") ? tree.find(stage.path.sub(%r{/[^/]+\z}, "")) : nil
        siblings = parent ? parent.children : tree.stages
        stage.depends_on.filter_map do |id|
          sibling = siblings.find { |candidate| candidate.id == id }
          [id, sibling] unless sibling.nil? || DONE.include?(sibling.effective_state)
        end.to_h
      end

      # @return [String, nil] `check_pending` or `check_failed` when the sibling claims completed without a passing check
      def wait_reason(sibling)
        return "check_failed" if sibling.check_failed?
        return "check_pending" if sibling.awaiting_check?
        sub = sibling.children.map { |child| wait_reason(child) }
        sub.include?("check_failed") ? "check_failed" : sub.compact.first
      end

      def find_play(stage, ref, cwd)
        ref ||= stage.file.value("play")
        return @library.play(ref, cwd: cwd) if ref
        builtin = KIND_PLAYS[stage.kind]
        builtin && @library.pack(builtin, cwd: cwd).first
      end

      def no_session(name)
        Workspace::Error.new("No active tmux session for '#{name}'.\nRun 'workspace launch #{name}' to start it, or leave out --pane and --spawn.",
          code: "no_session", details: {"workspace" => name})
      end

      def in_pane(job, named)
        name = job[:name]
        stage = job[:stage]
        panes = @panes.panes(name)
        owner_id = stage.file.value("owner")
        owner = owner_id && panes.find { |candidate| candidate["pane_id"] == owner_id }
        target = if named
          @panes.named(name, named, panes)
        else
          (owner if owner && AGENT_KINDS.include?(owner["kind"])) || @panes.main_pane(name, panes, preferred: owner_id, what: "the stage")
        end
        id = target["pane_id"]
        refuse_owned(name, stage, owner) if owner && owner["state"] == "working" && owner["pane_id"] != id
        @panes.require_agent(name, target, "stage")
        if target["state"] == "working" && owner_id == id && !stage.file.check_failed?
          @output.puts "Stage #{stage.path} of #{name} is already being worked on in pane #{id}."
          return doc(name, stage, "already_working", pane: id, play: job[:play])
        end
        @panes.refuse_busy(name, target, "stage")
        dispatch(job, id, target["kind"], "sent")
      end

      def by_spawn(job, kind)
        name = job[:name]
        stage = job[:stage]
        owner_id = stage.file.value("owner")
        if owner_id
          owner = @panes.panes(name).find { |candidate| candidate["pane_id"] == owner_id }
          refuse_owned(name, stage, owner) if owner && owner["state"] == "working"
        end
        spawned = @panes.spawn(name, kind)
        unless spawned.ready?
          message = "Started #{spawned.label} in new pane #{spawned.pane}, but it was not ready for the stage in #{@panes.prompt_timeout}s " \
            "(#{spawned.ready.reason}); nothing was typed or written."
          return doc(name, stage, "failed", reason: "prompt_not_sent", message: message, pane: spawned.pane, play: job[:play])
        end
        begin
          dispatch(job, spawned.pane, kind, "spawned")
        rescue Workspace::Error => e
          # A refusal under the write lock comes after the split: say the new pane is still there.
          raise Workspace::Error.new("#{e.message} The new pane #{spawned.pane} was left open.", code: e.code,
            details: e.details.merge("pane" => spawned.pane), retry_with: e.retry)
        end
      end

      def refuse_owned(name, stage, owner)
        raise Workspace::Error.new("Stage #{stage.path} of '#{name}' is being worked on in pane #{owner["pane_id"]}, so it was not started elsewhere. " \
          "Pause that pane first, or start the stage there.", code: "stage_owned", details: {"workspace" => name, "path" => stage.path, "owner" => owner["pane_id"]})
      end

      # Write, then type, then bind.
      def dispatch(job, id, kind, outcome)
        name = job[:name]
        stage, result = write(name, job[:stage].path, {"status" => "in_progress", "owner" => id}, "#{kind} #{id}", job[:if_revision])
        begin
          @panes.deliver(name, id, body: job[:body])
        rescue Workspace::Error => e
          return doc(name, stage, "failed", result: result, pane: id, play: job[:play], reason: e.code || "error",
            message: "#{e.message} #{reset_hint(name, stage, result)}")
        end
        note = @panes.bind_play(name, id, job[:play], focus: focus(stage), packs: [PACK])
        @output.puts "Started stage #{stage.path} of #{name}: sent it to #{(outcome == "spawned") ? "new pane" : "pane"} #{id}."
        @output.puts note if note
        doc(name, stage, outcome, result: result, pane: id, message: note, play: job[:play])
      end

      # A workspace with no session: the status is written before the launch, so the agent reads it as started;
      # the owner, once the launch names the pane.
      def by_launch(name, stage, entry, brief, launch, if_revision)
        stage, result = write(name, stage.path, {"status" => "in_progress"}, LAUNCH_BY, if_revision)
        launched = launch.call(name, entry && entry["ref"], brief)
        unless launched[:ok]
          return doc(name, stage, "failed", result: result, play: entry, reason: launched[:reason] || "launch_failed",
            message: [launched[:message], reset_hint(name, stage, result)].compact.join(" "))
        end
        id = launched[:pane]
        previous = result.previous
        notes = []
        if id
          begin
            stage, result = write(name, stage.path, {"owner" => id}, LAUNCH_BY, nil)
          rescue Workspace::Error => e
            notes << "Could not record pane #{id} as the owner of #{stage.path} (#{e.message}); run: workspace spine set #{name} #{stage.path} --owner #{id}"
          end
          notes << @panes.bind_play(name, id, entry, focus: focus(stage), packs: [PACK])
        end
        notes.compact!
        @output.puts "Started stage #{stage.path} of #{name}: launched it#{" with the #{entry["ref"]} play" if entry}."
        notes.each { |text| @output.puts text }
        doc(name, stage, "launched", result: result, previous: previous, play: entry, pane: id, message: notes.empty? ? nil : notes.join(" "))
      end

      # The one locked write; the file-only refusals are made again on what the lock lets it read.
      def write(name, path, values, by, if_revision)
        @spine.write_one(name: name, path: path, values: values, by: by, if_revision: if_revision) do |tree, fresh|
          refuse(name, tree, fresh, nil)
        end
      end

      def focus(stage) = "spine stage #{stage.path}"

      def reset_hint(name, stage, result)
        "#{stage.path} was left #{result.status} with owner #{result.owner || "none"}; to set it back, run: " \
          "workspace spine set #{Shellwords.escape(name)} #{Shellwords.escape(stage.path)} --status #{result.previous} --owner #{Shellwords.escape(result.previous_owner.to_s)}"
      end

      def doc(name, stage, outcome, result: nil, previous: nil, play: nil, pane: nil, reason: nil, message: nil)
        file = stage.file
        {"schema_version" => JSON_SCHEMA_VERSION, "ok" => outcome != "failed", "workspace" => name, "path" => stage.path, "file" => stage.relative,
         "outcome" => outcome, "reason" => reason, "pane" => pane,
         "owner" => result ? result.owner : file.value("owner"), "status" => result ? result.status : stage.status,
         "previous" => previous || (result ? result.previous : stage.status), "revision" => result ? result.revision : file.revision,
         "play" => play && play["ref"], "message" => message}
      end
    end
  end
end
