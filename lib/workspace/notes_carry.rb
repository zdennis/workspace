require "fileutils"
require "securerandom"

module Workspace
  # Carries the notes of the work `workspace promote` moves from a main checkout's notes
  # directory into the new workspace's: `IMPLEMENTATION_PLAN.md` and `spine/` move (the old
  # ones are renamed `<name>.moved-<time>`, never deleted), and each named note is copied.
  #
  # It never overwrites a file in the new directory and never follows a link: a clash or a
  # link is a warning and that item is left out. Nothing here raises for a problem with an
  # item; each one comes back as an outcome and a warning.
  class NotesCarry
    # The file name of the plan, as `PlanFile` has it.
    PLAN_FILE = PlanFile::FILE_NAME

    # @param spine_init [Workspace::Commands::SpineInit, nil] adds the ship stage a moved spine lacks
    # @param clock [#call] returns the Time that stamps a renamed original
    def initialize(spine_init: nil, clock: -> { Time.now })
      @spine_init = spine_init
      @clock = clock
    end

    # @param from [String] the main checkout's notes directory
    # @param to [String] the new workspace's notes directory
    # @param name [String, nil] the new workspace; with it a moved spine gets its ship stage
    # @param carry_notes [Array<String>] paths relative to +from+
    # @param dry_run [Boolean] report `would_*` outcomes and write nothing
    # @return [Hash] `plan` and `spine` (`moved`, `none`, `skipped`; `would_move` on a dry run),
    #   `ship` (`SpineInit#add_missing_ship`'s outcome, nil when there was no spine moved),
    #   `carried` (`{"path", "outcome"}` with `copied`, `missing`, `skipped`; `would_copy` on a dry run)
    #   and `warnings` (`{"code", "message", ...}`)
    def call(from:, to:, name: nil, carry_notes: [], dry_run: false)
      @warnings = []
      @dry_run = dry_run
      @moved = []
      @stamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
      from = File.expand_path(from)
      to = File.expand_path(to)
      if nested?(from, to)
        warn_item("same_notes_dir", "The main checkout's notes directory (#{from}) and the new workspace's (#{to}) are the same, or one is inside what would be moved; nothing was carried.", "path" => to)
        return {"plan" => "skipped", "spine" => "skipped", "ship" => nil, "warnings" => @warnings,
                "carried" => carry_notes.map { |p| {"path" => p, "outcome" => "skipped"} }}
      end

      plan = move_item(from, to, PLAN_FILE, directory: false)
      spine = move_item(from, to, "spine", directory: true)
      @moved << PLAN_FILE if %w[moved would_move].include?(plan)
      @moved << "spine" if %w[moved would_move].include?(spine)
      {"plan" => plan, "spine" => spine, "ship" => ship(spine, from, to, name),
       "carried" => carry_notes.uniq.map { |path| carry(from, to, path) }, "warnings" => @warnings}
    end

    private

    # The new directory may sit inside the main one (the default is `<main notes>/<branch>`), but not
    # inside what is moved, and the main one may not sit inside the new one.
    def nested?(from, to)
      a = real(from) + "/"
      b = real(to) + "/"
      return true if a.start_with?(b)
      b.start_with?(a + "spine/") || b.start_with?(a + PLAN_FILE + "/")
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      parent = File.dirname(path)
      (parent == path) ? path : File.join(real(parent), File.basename(path))
    end

    # True when a folder on the way down from +root+ to the last of +parts+ is a link.
    def through_link?(root, parts)
      walk = root
      parts[0...-1].any? do |part|
        walk = File.join(walk, part)
        File.symlink?(walk)
      end
    end

    def move_item(from, to, rel, directory:)
      source = File.join(from, rel)
      stat = begin
        File.lstat(source)
      rescue Errno::ENOENT
        return "none"
      end
      if stat.symlink?
        warn_item("notes_link", "#{source} is a link; it was not moved.", "path" => source)
        return "skipped"
      end
      unless directory ? stat.directory? : stat.file?
        warn_item("notes_not_#{directory ? "directory" : "file"}", "#{source} is not a #{directory ? "directory" : "file"}; it was not moved.", "path" => source)
        return "skipped"
      end
      target = File.join(to, rel)
      return clash(target) if File.exist?(target) && !(directory && empty_directory?(target)) || File.symlink?(target)
      return "would_move" if @dry_run

      FileUtils.mkdir_p(to)
      directory ? copy_tree(source, target) : copy_file(source, target)
      rename_original(source)
      "moved"
    rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOTDIR
      clash(File.join(to, rel))
    rescue SystemCallError => e
      warn_item("notes_unwritable", "Could not move #{File.join(from, rel)}: #{e.message}.", "path" => File.join(from, rel))
      "skipped"
    end

    def clash(target)
      warn_item("notes_clash", "#{target} is there already; the one in the main checkout was left alone.", "path" => target)
      "skipped"
    end

    def empty_directory?(path)
      File.directory?(path) && !File.symlink?(path) && Dir.empty?(path)
    end

    # Copies to a temp file beside +target+ and links it into place only after the whole copy, so a
    # failed copy leaves no partial file and a target that appeared meanwhile is never replaced
    # (Errno::EEXIST).
    def copy_file(source, target)
      tmp = File.join(File.dirname(target), ".#{File.basename(target)}.tmp-#{SecureRandom.hex(8)}")
      File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, input.stat.mode & 0o777) do |output|
          IO.copy_stream(input, output)
        end
      end
      File.link(tmp, target)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    # Builds the copy beside +target+ and renames it into place, so a reader sees all of it or none.
    # Links inside the tree are left out with a warning.
    def copy_tree(source, target)
      tmp = nil
      begin
        tmp = make_temp_dir(target)
        copy_entries(source, tmp)
        File.rename(tmp, target)
      ensure
        FileUtils.rm_rf(tmp) if tmp
      end
    end

    # A fresh directory beside +target+ under a random name; creating it is retried on a name clash.
    def make_temp_dir(target)
      attempts = 0
      begin
        tmp = "#{target}.tmp-#{SecureRandom.hex(8)}"
        Dir.mkdir(tmp)
        tmp
      rescue Errno::EEXIST
        retry if (attempts += 1) < 5
        raise
      end
    end

    def copy_entries(source, dest)
      Dir.mkdir(dest) unless File.directory?(dest)
      Dir.children(source).sort.each do |child|
        from = File.join(source, child)
        to = File.join(dest, child)
        stat = File.lstat(from)
        if stat.directory?
          copy_entries(from, to)
        elsif stat.file?
          copy_file(from, to)
        else
          warn_item("notes_link", "#{from} is a link or special file; it was not moved with its folder.", "path" => from)
        end
      end
    end

    def rename_original(source)
      target = "#{source}.moved-#{@stamp}"
      suffix = 0
      target = "#{source}.moved-#{@stamp}-#{suffix += 1}" while File.exist?(target) || File.symlink?(target)
      File.rename(source, target)
    rescue SystemCallError => e
      warn_item("notes_not_renamed", "Moved #{source}, but could not rename the original: #{e.message}.", "path" => source)
    end

    def ship(spine, from, to, name)
      return nil unless @spine_init && name
      case spine
      when "moved"
        outcome = @spine_init.add_missing_ship(name: name, spine_dir: File.join(to, "spine"))["outcome"]
        warn_item("ship_not_added", "The ship stage could not be added to the moved spine.", {}) if outcome == "skipped"
        outcome
      when "would_move"
        shipped = Dir.children(File.join(from, "spine")).any? { |c| Commands::SpineInit::SHIP_STAGE.match?(c) }
        shipped ? "present" : "would_add"
      end
    rescue Workspace::Error, SystemCallError => e
      warn_item("ship_not_added", "Could not add the ship stage: #{e.message}", {})
      "skipped"
    end

    def carry(from, to, rel)
      outcome = copy_note(from, to, rel.to_s)
      {"path" => rel, "outcome" => outcome}
    end

    def copy_note(from, to, rel)
      parts = rel.split("/").reject(&:empty?)
      if rel.start_with?("/") || parts.empty? || parts.include?("..") || rel.include?("\0")
        warn_item("carry_note_invalid", "#{rel.inspect} is not a path inside the main checkout's notes directory; it was not copied.", "path" => rel)
        return "skipped"
      end
      if @moved.include?(parts.first)
        warn_item("carry_note_already_carried", "#{rel} is part of #{parts.first}, which was moved whole; it was not copied again.", "path" => rel)
        return "skipped"
      end
      source = File.join(from, *parts)
      stat = nil
      walk = from
      parts.each do |part|
        walk = File.join(walk, part)
        stat = File.lstat(walk)
        next unless stat.symlink?
        warn_item("carry_note_link", "#{walk} is a link; #{rel} was not copied.", "path" => rel)
        return "skipped"
      end
      unless stat.file?
        warn_item("carry_note_not_file", "#{rel} is not a file; it was not copied.", "path" => rel)
        return "skipped"
      end
      if through_link?(to, parts)
        warn_item("carry_note_link", "#{rel} would be written through a link; it was not copied.", "path" => rel)
        return "skipped"
      end
      target = File.join(to, *parts)
      if File.exist?(target) || File.symlink?(target)
        warn_item("carry_note_clash", "#{target} is there already; #{rel} was not copied over it.", "path" => rel)
        return "skipped"
      end
      return "would_copy" if @dry_run

      FileUtils.mkdir_p(File.dirname(target))
      copy_file(source, target)
      "copied"
    rescue Errno::ENOENT, Errno::ENOTDIR
      warn_item("carry_note_missing", "#{rel} is not in the main checkout's notes directory.", "path" => rel)
      "missing"
    rescue Errno::EEXIST
      warn_item("carry_note_clash", "#{File.join(to, rel)} appeared while #{rel} was copied; it was not replaced.", "path" => rel)
      "skipped"
    rescue SystemCallError => e
      warn_item("carry_note_unwritable", "Could not copy #{rel}: #{e.message}.", "path" => rel)
      "skipped"
    end

    def warn_item(code, message, extra)
      @warnings << {"code" => code, "message" => message}.merge(extra)
    end
  end
end
