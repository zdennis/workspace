require "open3"
require "tmpdir"

module Workspace
  # A unified diff of two texts, made by `diff -u` over two temporary files (the one process the tree
  # starts for it). `template render --diff` takes it as `differ:`; a spec passes a lambda of the same shape.
  class TextDiff
    # @param old_text [String]
    # @param new_text [String]
    # @param old_label [String] the `---` line's name
    # @param new_label [String] the `+++` line's name
    # @return [String] the diff; empty when the texts are the same
    # @raise [Workspace::Error] when `diff` can't be run
    def call(old_text, new_text, old_label:, new_label:)
      Dir.mktmpdir("workspace-diff") do |dir|
        old_path = File.join(dir, "old")
        new_path = File.join(dir, "new")
        File.write(old_path, old_text)
        File.write(new_path, new_text)
        out, err, status = Open3.capture3("diff", "-u", "--label", old_label, "--label", new_label, old_path, new_path)
        raise Error, "diff failed: #{err.strip}" unless status.exitstatus.between?(0, 1)
        out
      end
    rescue SystemCallError => e
      raise Error, "Can't run diff: #{e.message}"
    end
  end
end
