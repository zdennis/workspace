module Workspace
  # Fills a workflow's +task+ and +pr+ inputs from the branch a checkout is on, for a run started
  # with no ref and no prompt.
  class WorkflowBranchInputs
    # The input names a branch can fill.
    FILLABLE = %w[task pr].freeze

    # @param git [#worktree_branch] answers the branch checked out at a path
    # @param start_ref [#project] finds the project a checkout belongs to
    # @param protected_branch [#call] answers non-nil for a default or main checkout branch
    # @param pull_request_status [#summary] reads the branch's pull request
    def initialize(git:, start_ref:, protected_branch:, pull_request_status:)
      @git = git
      @start_ref = start_ref
      @protected_branch = protected_branch
      @pull_request_status = pull_request_status
    end

    # @param definition [#to_h] a workflow definition
    # @param worktree [String] the checkout to read
    # @param inputs [Hash{String=>String}] the inputs already given; never changed
    # @return [Array(Hash, Hash)] the inputs with the filled ones added, and where each filled
    #   one came from (+{"task" => "pull_request", "pr" => "pull_request"}+, or +"branch"+ for the task);
    #   the inputs and +{}+ when nothing is filled or anything cannot be read
    def call(definition, worktree, inputs)
      names = FILLABLE.select { |name| WorkflowSeed.fillable?(definition, name, inputs) }
      return [inputs, {}] if names.empty?

      branch = @git.worktree_branch(worktree)
      return [inputs, {}] if branch.nil? || @protected_branch.call(branch, @start_ref.project(worktree))

      values = values_for(@pull_request_status.summary(worktree), branch).slice(*names)
      return [inputs, {}] if values.empty?

      [inputs.merge(values.transform_values(&:first)), values.transform_values(&:last)]
    rescue SystemCallError, Workspace::Error
      [inputs, {}]
    end

    private

    def values_for(summary, branch)
      if summary["available"] && summary["found"] && summary["state"] == "OPEN" && summary["number"].is_a?(Integer)
        ticket = {"key" => "##{summary["number"]}", "title" => summary["title"], "url" => summary["url"]}
        {"pr" => [summary["number"].to_s, "pull_request"],
         "task" => [WorkflowSeed.task_text(ticket, nil), "pull_request"]}
      else
        {"task" => ["Branch #{branch}", "branch"]}
      end
    end
  end
end
