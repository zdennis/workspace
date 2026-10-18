require "securerandom"

module Workspace
  # The status requests one agent daemon has open: at most one per pane, each
  # tied to the pane's id and the pid tmux started in it, and each expiring.
  # Held in memory only, so a daemon restart drops them and a late reply is
  # refused as unknown.
  #
  # Thread-safe: requests open on worker threads while posts are checked on
  # the daemon's accept loop.
  class AgentStatusRequests
    # Seconds a request stays open.
    DEFAULT_TTL = 600

    # One open request.
    Request = Struct.new(:id, :pane_id, :pane_pid, :opened_at, :expires_at, keyword_init: true)

    # @param ttl [Numeric] seconds a request stays open
    # @param clock [#call] the current Time
    # @param id_generator [#call] a new request id
    def initialize(ttl: DEFAULT_TTL, clock: -> { Time.now }, id_generator: -> { "sr-#{SecureRandom.hex(6)}" })
      @ttl = ttl
      @clock = clock
      @id_generator = id_generator
      @requests = {}
      @lock = Mutex.new
    end

    # Opens a request on a pane, unless one is already open there.
    #
    # @param pane_id [String] tmux pane id
    # @param pane_pid [Integer] the pid tmux started in the pane
    # @return [Array(Symbol, Request)] `[:opened, request]`, or `[:open, the open request]`
    def open(pane_id:, pane_pid:)
      now = @clock.call
      @lock.synchronize do
        @requests.delete_if { |_, r| r.expires_at <= now }
        existing = @requests.values.find { |r| r.pane_id == pane_id }
        next [:open, existing] if existing

        request = Request.new(id: @id_generator.call, pane_id: pane_id, pane_pid: pane_pid, opened_at: now, expires_at: now + @ttl)
        @requests[request.id] = request
        [:opened, request]
      end
    end

    # Forgets a request whose text never reached its pane.
    #
    # @param id [String]
    # @return [void]
    def cancel(id)
      @lock.synchronize { @requests.delete(id) }
    end

    # Closes the request a reply answers, in one step, so two replies can't
    # both answer it. A refused reply leaves the request open for the pane
    # that was asked; an expired request is forgotten.
    #
    # @param id [String] the request named by `--reply-to`
    # @param pane_id [String] the replying pane
    # @param pane_pid [Integer, nil] that pane's pid now
    # @return [Array(String, Request)] nil and the closed request when the
    #   reply fits, or an error code: `status_request_unknown`,
    #   `status_request_expired`, `status_reply_wrong_pane` or `status_request_stale`
    def claim(id, pane_id:, pane_pid:)
      now = @clock.call
      @lock.synchronize do
        request = @requests[id]
        next ["status_request_unknown", nil] unless request
        if request.expires_at <= now
          @requests.delete(id)
          next ["status_request_expired", request]
        end
        next ["status_reply_wrong_pane", request] unless request.pane_id == pane_id
        next ["status_request_stale", request] unless request.pane_pid == pane_pid
        [nil, @requests.delete(id)]
      end
    end

    # Opens a claimed request again, when its reply couldn't be logged.
    # Nothing happens if the pane has opened another request meanwhile.
    #
    # @param request [Request]
    # @return [void]
    def reopen(request)
      @lock.synchronize do
        @requests[request.id] = request unless @requests.values.any? { |r| r.pane_id == request.pane_id }
      end
    end
  end
end
