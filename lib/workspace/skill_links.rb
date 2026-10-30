require "fileutils"
require "shellwords"

module Workspace
  # Reads, plans and writes the symlinks of the four workspace skills in one
  # skills directory. Only the four named paths are touched; each is a symlink to
  # the skill's whole directory. A path that exists and is not our link is never
  # replaced: an identical real directory is moved to the state directory's
  # `skill-backups`, anything else is refused with the `mv` that would clear it.
  class SkillLinks
    # One skill in one directory. `outcome` is `linked`, `relinked`, `adopted`,
    # `unchanged`, `removed`, `left`, `skipped`, `refused` or `failed`.
    Step = Struct.new(:dir, :name, :state, :from, :to, :outcome, :code, :message, :mv, :backup)

    # The steps for one directory; `refused?` is true when any step is refused, and then none is written.
    Plan = Struct.new(:dir, :steps, :warnings) do
      def refused?
        steps.any? { |step| step.outcome == "refused" }
      end
    end

    # @param state_dir [String] holds `skill-backups/`
    # @param clock [#call] returns the current Time
    def initialize(state_dir:, clock: -> { Time.now })
      @state_dir = state_dir
      @clock = clock
    end

    # Whether the symlink at `path` is ours: it is named `name`, and points at a
    # `lib/skills/<name>` of this tool (a Homebrew Cellar path, a dangling link, or a
    # directory with `bin/workspace` two levels above its `lib`).
    #
    # @param path [String]
    # @param name [String]
    # @return [Boolean]
    def ours?(path, name)
      return false unless File.symlink?(path) && File.basename(path) == name
      target = link_target(path)
      return false unless target.end_with?("/lib/skills/#{name}")
      return true if target.include?("/Cellar/")
      return File.file?(File.expand_path("../../../bin/workspace", target)) if File.exist?(target)
      File.basename(File.expand_path("../../..", target)).match?(/workspace/i) || whole_set?(File.dirname(path), File.expand_path("..", target))
    end

    # @param dir [String] a skills directory
    # @param name [String]
    # @param root [String] the source directory the link should name
    # @return [Symbol] `:absent`, `:current`, `:ours` (another root, or dangling), `:adoptable`
    #   (a real directory equal to the source), `:directory`, `:file` or `:foreign`
    def inspect_path(dir, name, root)
      path = File.join(dir, name)
      if File.symlink?(path)
        return :foreign unless ours?(path, name)
        (link_target(path) == File.join(root, name)) ? :current : :ours
      elsif !File.exist?(path)
        :absent
      elsif File.directory?(path)
        same_content?(path, File.join(root, name)) ? :adoptable : :directory
      else
        :file
      end
    end

    # @param dir [String]
    # @param root [String]
    # @param names [Array<String>]
    # @return [Plan] what an install would do, with nothing written
    def plan(dir, root, names)
      warnings = []
      steps = names.map { |name| step_for(dir, name, root) }
      if File.symlink?(dir) && !File.exist?(dir)
        steps.each { |step| refuse(step, "skill_path_exists", "#{dir} is a link to #{File.readlink(dir)}, which does not exist.", dir) }
      elsif File.exist?(dir) && !File.directory?(dir)
        steps.each { |step| refuse(step, "skill_path_exists", "#{dir} exists and is not a directory.", dir) }
      elsif File.directory?(dir)
        real = File.realpath(dir)
        warnings << "#{dir} is a link; writing through it to #{real}." if File.symlink?(dir)
        source_real = File.realpath(root)
        if real == source_real || real.start_with?("#{source_real}/") || source_real.start_with?("#{real}/")
          steps.each { |step| refuse(step, "skill_path_exists", "#{dir} is, or holds, the skills source #{source_real}; linking there would replace the source.", dir) }
        end
      end
      if steps.any? { |step| step.outcome == "refused" }
        steps.each { |step| step.outcome = "skipped" if step.outcome != "refused" }
      end
      Plan.new(dir, steps, warnings)
    end

    # Writes a plan that holds no refusal. A failure undoes what the plan already
    # did in this directory and marks its steps `failed`.
    #
    # @param plan [Plan]
    # @return [void]
    def apply(plan)
      return if plan.refused?
      undo = []
      FileUtils.mkdir_p(plan.dir)
      plan.steps.each do |step|
        next if step.outcome == "unchanged"
        write(step, undo)
      end
    rescue SystemCallError => e
      undo.reverse_each do |action|
        action.call
      rescue SystemCallError
        nil
      end
      plan.steps.each do |step|
        next if step.outcome == "unchanged"
        step.outcome = "failed"
        step.code = "skill_link_failed"
        step.message = e.message
      end
    end

    # Removes the symlink of one of ours.
    #
    # @param step [Step]
    # @return [void]
    def remove(step)
      File.unlink(File.join(step.dir, step.name))
      step.outcome = "removed"
    rescue SystemCallError => e
      step.outcome = "failed"
      step.code = "skill_link_failed"
      step.message = e.message
    end

    # What uninstall finds in a directory: one step per skill name that has
    # something at its path. Ours are `removed` (not yet removed); the rest are `left`.
    #
    # @param dir [String]
    # @param names [Array<String>]
    # @return [Array<Step>]
    def removal_steps(dir, names)
      names.filter_map do |name|
        path = File.join(dir, name)
        next unless File.symlink?(path) || File.exist?(path)
        step = Step.new(dir, name, nil, link_or_kind(path), nil)
        if ours?(path, name)
          step.outcome = "removed"
        else
          step.outcome = "left"
          step.code = File.symlink?(path) ? "skill_link_foreign" : "skill_path_exists"
          step.message = File.symlink?(path) ? "#{path} is someone else's link; left alone." : "#{path} is not our link; left alone."
        end
        step
      end
    end

    private

    # A dangling link counts as ours when all four names in the directory point into the same
    # lib/skills root: a checkout that was deleted or moved away, whatever it was called.
    def whole_set?(dir, root)
      SkillSource::NAMES.all? do |name|
        path = File.join(dir, name)
        File.symlink?(path) && link_target(path) == File.join(root, name)
      end
    end

    def step_for(dir, name, root)
      path = File.join(dir, name)
      to = File.join(root, name)
      state = inspect_path(dir, name, root)
      step = Step.new(dir, name, state, link_or_kind(path), to)
      case state
      when :absent then step.outcome = "linked"
      when :current then step.outcome = "unchanged"
      when :ours then step.outcome = "relinked"
      when :adoptable
        step.outcome = "adopted"
        step.backup = backup_path(dir, name)
      when :directory
        refuse(step, "skill_path_exists", "#{path} is a real directory with other content.", path)
      when :file
        refuse(step, "skill_path_exists", "#{path} is a file.", path)
      when :foreign
        refuse(step, "skill_link_foreign", "#{path} is a link to #{link_target(path)}, which is not this tool's.", path)
      end
      step
    end

    def refuse(step, code, message, path)
      keep = File.dirname(backup_path(File.dirname(path), File.basename(path)))
      step.outcome = "refused"
      step.code = code
      step.message = message
      step.mv = "mkdir -p #{keep.shellescape} && mv #{path.shellescape} #{keep.shellescape}/"
    end

    def write(step, undo)
      path = File.join(step.dir, step.name)
      case step.state
      when :adoptable
        FileUtils.mkdir_p(File.dirname(step.backup))
        FileUtils.mv(path, step.backup)
        undo << -> { FileUtils.mv(step.backup, path) unless File.exist?(path) || File.symlink?(path) }
        begin
          swap(path, step.to)
        rescue SystemCallError
          FileUtils.mv(step.backup, path)
          raise
        end
        undo << -> { File.unlink(path) if File.symlink?(path) }
      when :ours
        old = File.readlink(path)
        swap(path, step.to)
        undo << -> { swap(path, old) }
      else
        swap(path, step.to)
        undo << -> { File.unlink(path) if File.symlink?(path) }
      end
    end

    # Points `path` at `target` by making a temp link beside it and renaming it into place.
    def swap(path, target)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.symlink(target, tmp)
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && File.symlink?(tmp)
    end

    def backup_path(dir, name)
      stamp = @clock.call.strftime("%Y%m%d-%H%M%S")
      File.join(@state_dir, "skill-backups", stamp, dir.gsub(/[^A-Za-z0-9._-]+/, "_"), name)
    end

    def link_target(path)
      File.expand_path(File.readlink(path), File.dirname(path))
    end

    def link_or_kind(path)
      return link_target(path) if File.symlink?(path)
      return nil unless File.exist?(path)
      File.directory?(path) ? "directory" : "file"
    end

    def same_content?(path, source)
      strip = ->(snapshot) { snapshot.reject { |rel, _| File.basename(rel) == ".DS_Store" } }
      strip.call(LibraryStore.snapshot(path)) == strip.call(LibraryStore.snapshot(source))
    rescue SystemCallError
      false
    end
  end
end
