require "fileutils"

module Workspace
  # A step's instructions: the text composed from its packs, prompt and checks, where an attempt's file goes, the
  # binding its pane gets, and the file itself. A delivered attempt and a preview ({WorkflowEngine#render}) ask
  # the same methods, so the two can't drift. Each method takes the run as a {WorkflowRun} or the stored Hash.
  class WorkflowPrompt
    # @param composer [Workspace::InstructionComposer] builds a step's instructions from its packs
    # @param git [Workspace::Git] reads the checkout's branch for `{{branch}}`
    # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
    # @param prompt_writer [#call] writes the file, given the path, the text and an +encoding:+, as +File.write+ does
    def initialize(composer:, git:, excludes:, prompt_writer: File.method(:write))
      @composer = composer
      @git = git
      @excludes = excludes
      @prompt_writer = prompt_writer
    end

    # @param worktree [String] the run's checkout
    # @param run_id [String]
    # @return [String] the directory a run's artifacts and instructions live in
    def artifacts_dir(worktree, run_id)
      File.join(worktree, ".workflow", run_id)
    end

    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param step [Hash{String=>Object}] the step's definition
    # @param context [Array<String>] what this attempt is told besides (a note, a failure)
    # @param binding [Hash{String=>Object}, nil] the binding the pane will have, for the `binding` pack
    # @return [Hash{String=>Object}] the composer's answer: "text" and "packs"
    # @raise [Workspace::Error] for text that is not UTF-8, and the composer's errors for a pack that can't be read
    def compose(run, step, context, binding: nil)
      run = WorkflowRun.from_h(run)
      data = run.definition
      filled = values(run)
      context = context.dup
      context.unshift("Note for this run: #{run.note}") if run.note
      @composer.compose(
        packs: nil, cwd: run.worktree, binding: binding, skip: step["uses"].to_a.include?("devenv") ? ["dev"] : [],
        workflow: {"name" => data["id"], "include" => data["include"],
                   "text" => data["instructions"] && WorkflowDefinition.render(data["instructions"], filled)},
        step: {"name" => step["id"], "include" => step["include"], "text" => step_text(run, step, filled)},
        attempt: context
      )
    rescue EncodingError, ArgumentError => e
      # Text that is not UTF-8 met text that is (a pack read with no UTF-8 locale, a checkout under
      # such a path): an encoding error, or the "invalid byte sequence" a string method raises.
      raise unless e.is_a?(EncodingError) || e.message.include?("invalid byte sequence")
      raise Workspace::Error, "the step's instructions could not be put together: a pack, a prompt or a path is not UTF-8 text (#{e.class})"
    end

    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param step [Hash{String=>Object}]
    # @param attempt_number [Integer]
    # @return [String] where the attempt's instructions file goes
    def prompt_path(run, step, attempt_number)
      File.join(WorkflowRun.from_h(run).artifacts_dir, "steps", "#{step["id"]}.#{attempt_number}.prompt.md")
    end

    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param step [Hash{String=>Object}]
    # @param attempt_number [Integer]
    # @param path [String] the instructions file
    # @return [Hash{String=>Object}] the binding the attempt's pane gets
    def step_binding(run, step, attempt_number, path)
      run = WorkflowRun.from_h(run)
      {"kind" => "run", "id" => run.id, "workspace" => run.workspace, "step" => step["id"], "attempt" => attempt_number,
       "instructions" => path, "artifacts" => run.artifacts_dir}
    end

    # Writes an attempt's instructions file, with `.workflow/` listed in the checkout's `info/exclude`.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param step [Hash{String=>Object}]
    # @param attempt_number [Integer]
    # @param context [Array<String>]
    # @return [Array(String, Hash{String=>Object})] the file's path and what {#compose} answered
    # @raise [Workspace::Error, SystemCallError, EncodingError] when the text can't be composed or written
    def write(run, step, attempt_number, context)
      run = WorkflowRun.from_h(run)
      FileUtils.mkdir_p(File.join(run.artifacts_dir, "steps"))
      @excludes.add(run.worktree, "/.workflow/")
      path = prompt_path(run, step, attempt_number)
      composed = compose(run, step, context, binding: step_binding(run, step, attempt_number, path))
      @prompt_writer.call(path, composed["text"], encoding: Encoding::UTF_8)
      [path, composed]
    end

    private

    def values(run)
      branch = begin
        @git.worktree_branch(run.worktree)
      rescue Workspace::Error, SystemCallError
        nil
      end
      {"workspace" => run.workspace, "branch" => branch.to_s, "artifacts" => run.artifacts_dir, "run" => run.id}
        .merge(run.inputs.transform_keys { |name| "inputs.#{name}" })
    end

    # The prompt, then what the runner looks at when the turn ends.
    def step_text(run, step, filled)
      text = WorkflowDefinition.render(step["prompt"], filled).strip
      files = step["produces"].map { |file| File.join(run.artifacts_dir, file) }
      if files.any?
        what = WorkflowProduced.strict?(run.definition) ? "exist as non-empty regular files (not links), written during this attempt" : "exist, written during this attempt"
        text += "\n\nThis step is finished when your turn ends and these files #{what}: #{files.join(", ")}."
      end
      text += "\n\nWhen your turn ends, the runner checks the step with the project's own command; work until it would pass." if step["status"]
      text
    end
  end
end
