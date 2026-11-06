# frozen_string_literal: true

require "delegate"

# A store over a real one that fails on demand: the next +update+ once, or every
# +get+ of the given pane ids.
class FailingStore < SimpleDelegator
  def initialize(store)
    super
    @fail_update_once = false
    @failing_gets = {}
  end

  def fail_next_update(message)
    @fail_update_once = message
  end

  def fail_get_for(pane_id, error)
    @failing_gets[pane_id] = error
  end

  def update(...)
    if @fail_update_once
      message = @fail_update_once
      @fail_update_once = false
      raise message
    end
    super
  end

  def get(pane_id)
    raise @failing_gets[pane_id] if @failing_gets.key?(pane_id)
    super
  end
end
