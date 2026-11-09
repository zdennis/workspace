# frozen_string_literal: true

# A real State that counts how many times it was saved.
class CountingState < Workspace::State
  attr_reader :save_count

  def initialize(**)
    super
    @save_count = 0
  end

  def save
    @save_count += 1
    super
  end
end
