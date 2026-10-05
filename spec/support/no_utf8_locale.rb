# Runs a block as a process with no UTF-8 locale reads files: `File.read`
# without an encoding tags the text US-ASCII, as it does under `LC_ALL=C`,
# cron, or an app started by launchd.
module NoUtf8Locale
  def without_utf8_locale
    was = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = Encoding::US_ASCII
    yield
  ensure
    Encoding.default_external = was
    $VERBOSE = verbose
  end
end

RSpec.configure { |config| config.include NoUtf8Locale }
