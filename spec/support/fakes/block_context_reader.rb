# frozen_string_literal: true

# A context reader whose +read(pane_id:, **)+ runs the given block with the pane id.
class BlockContextReader
  def initialize(&on_read)
    @on_read = on_read
  end

  def read(pane_id:, **)
    @on_read.call(pane_id)
  end
end
