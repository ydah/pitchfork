# Copyright (c) 2009 Eric Wong
require 'test/test_helper'

# don't call exit(0) since it may be run under rake (but gmake is recommended)
do_test = true

$unicorn_rails_bin = ENV['UNICORN_RAILS_TEST_BIN'] || "unicorn_rails"
redirect_test_io { do_test = system($unicorn_rails_bin, '-v') }

unless do_test
  warn "#$unicorn_rails_bin not found in PATH=#{ENV['PATH']}, " \
       "skipping this test"
end

unless which('git')
  warn "git not found in PATH=#{ENV['PATH']}, skipping this test"
  do_test = false
end

if RAILS_GIT_REPO = ENV['RAILS_GIT_REPO']
  unless File.directory?(RAILS_GIT_REPO)
    warn "#{RAILS_GIT_REPO} not found, create it with:\n" \
         "\tgit clone --mirror git://github.com/rails/rails #{RAILS_GIT_REPO}" \
         "skipping this test for now"
    do_test = false
  end
else
  warn "RAILS_GIT_REPO not defined, don't know where to git clone from"
  do_test = false
end

unless UNICORN_RAILS_TEST_VERSION = ENV['UNICORN_RAILS_TEST_VERSION']
  warn 'UNICORN_RAILS_TEST_VERSION not defined in environment, ' \
       'skipping this test'
  do_test = false
end

RAILS_ROOT = "#{File.dirname(__FILE__)}/app-#{UNICORN_RAILS_TEST_VERSION}"
unless File.directory?(RAILS_ROOT)
  warn "unsupported UNICORN_RAILS_TEST_VERSION=#{UNICORN_RAILS_TEST_VERSION}"
  do_test = false
end

ROR_V = UNICORN_RAILS_TEST_VERSION.split(/\./).map { |x| x.to_i }
RB_V = RUBY_VERSION.split(/\./).map { |x| x.to_i }
if RB_V[0] >= 1 && RB_V[1] >= 9
  unless ROR_V[0] >= 2 && ROR_V[1] >= 3
    warn "skipping Ruby >=1.9 test with Rails <2.3"
    do_test = false
  end
end

class RailsTest < Test::Unit::TestCase
  trap(:QUIT, 'IGNORE')

  COMMON_TMP = Tempfile.new('unicorn_tmp') unless defined?(COMMON_TMP)

  HEAVY_CFG = <<-EOS
worker_processes 2
timeout 30
logger Logger.new('#{COMMON_TMP.path}')
  EOS

  def setup
    @pwd = Dir.pwd
    @tmpfile = Tempfile.new('unicorn_rails_test')
    @tmpdir = @tmpfile.path
    @tmpfile.close!
    assert_nothing_raised do
      FileUtils.cp_r(RAILS_ROOT, @tmpdir, :preserve => true)
    end
    Dir.chdir(@tmpdir)
    system('git', 'clone', '-nsq', RAILS_GIT_REPO, 'vendor/rails')
    Dir.chdir("#@tmpdir/vendor/rails") do
      system('git', 'reset', '-q', '--hard', "v#{UNICORN_RAILS_TEST_VERSION}")
    end
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port(@addr)
    @start_pid = $$
    @pid = nil
  end

  def test_launcher_defaults
    tmp_dirs = %w(cache pids sessions sockets)
    tmp_dirs.each { |dir| assert(! File.exist?("tmp/#{dir}")) }
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    wait_master_ready("test_stderr.#$$.log")
    tmp_dirs.each { |dir| assert(File.directory?("tmp/#{dir}")) }
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/foo"))
    assert_equal "FOO\n", res.body
    assert_match %r{^text/html\b}, res['Content-Type']
    assert_equal "4", res['Content-Length']
    assert_nil res['Status']
  end

  def test_cookies
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/foo/xcookie"))
    assert_equal "200", res.code
    assert_nil res['Status']
    cookies = res.get_fields('Set-Cookie')
    assert_equal 2, cookies.size
    assert_equal 1, cookies.grep(/\A_unicorn_rails_test\./).size
    assert_equal 1, cookies.grep(/\Afoo=cookie/).size
  end

  def test_session
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/foo/xnotice"))
    assert_equal "200", res.code
    assert_nil res['Status']
    cookies = res.get_fields('Set-Cookie')
    assert_equal 1, cookies.size
    assert_equal 1, cookies.grep(/\A_unicorn_rails_test\./).size
  end

  def test_post
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    uri = URI.parse("http://#@addr:#@port/foo/xpost")
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.post_form(uri, {"a" => "b", "c"=>"d"})
    assert_equal "200", res.code
    params = res.body.split(/\n/).grep(/^params:/)
    assert_equal 1, params.size
    params = eval(params[0].gsub!(/\Aparams:/, ''))
    assert_equal Hash, params.class
    assert_equal 'b', params['a']
    assert_equal 'd', params['c']
    assert_nil res['Status']
  end

  def test_post_upload
    # I don't trust myself to generate a multipart request by hand
    which('curl') or return

    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    wait_master_ready("test_stderr.#$$.log")
    tmp = Tempfile.new('random')
    sha1 = Digest::SHA1.new
    assert_nothing_raised do
      File.open("/dev/urandom", "rb") do |fp|
        256.times do
          buf = fp.sysread(4096)
          sha1.update(buf)
          tmp.syswrite(buf)
        end
      end
    end
    resp = `curl -isSfN -Ffile=@#{tmp.path} http://#@addr:#@port/foo/xpost`
    assert $?.success?
    resp = resp.split(/\r?\n/)
    grepped = resp.grep(/^sha1: (.{40})/)
    assert_equal 1, grepped.size
    assert_equal(sha1.hexdigest, /^sha1: (.{40})/.match(grepped.first)[1])

    grepped = resp.grep(/^Content-Type:\s+(.+)/i)
    assert_equal 1, grepped.size
    assert_match %r{^text/plain}, grepped.first.split(/\s*:\s*/)[1]

    assert_equal 0, resp.grep(/^Status:/i).size
  end

  def test_post_forbidden
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    uri = URI.parse("http://#@addr:#@port/foo/xpost")
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(uri)
    assert_equal "403", res.code
    assert_nil res['Status']
  end

  def test_get_404
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    uri = URI.parse("http://#@addr:#@port/asdf")
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(uri)
    assert_equal "404", res.code
    assert_nil res['Status']
  end

  def test_alt_url_root
    # cbf to actually work on this since I never use this feature (ewong)
    return unless ROR_V[0] >= 2 && ROR_V[1] >= 3
    redirect_test_io do
      @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port", '-P/poo' }
    end
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/poo/foo"))
    # p res
    # p res.body
    # system 'cat', 'log/development.log'
    assert_equal "200", res.code
    assert_equal "FOO\n", res.body
    assert_match %r{^text/html\b}, res['Content-Type']
    assert_equal "4", res['Content-Length']
    assert_nil res['Status']

    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/foo"))
    assert_equal "404", res.code
    assert_nil res['Status']
  end

  def test_static
    redirect_test_io { @pid = fork { exec 'unicorn_rails', "-l#@addr:#@port" } }
    wait_master_ready("test_stderr.#$$.log")
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/pid.txt"))
    assert_nil res['Status']
    assert_equal '404', res.code
    File.open("public/pid.txt", "wb") { |fp| fp.syswrite("#$$\n") }

    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/pid.txt"))
    assert_equal '200', res.code
    assert_match %r{^text/plain}, res['Content-Type']
    assert_equal "#$$\n", res.body
    assert_nil res['Status']

    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/500.html"))
    assert_equal '200', res.code
    assert_match %r{^text/html}, res['Content-Type']
    five_hundred_body = res.body
    assert_nil res['Status']

    assert ! File.exist?("public/500")
    assert File.exist?("public/500.html")
    assert_equal five_hundred_body, File.read("public/500.html")
    res = Net::HTTP.get_response(URI.parse("http://#@addr:#@port/500"))
    assert_equal '200', res.code
    assert_match %r{^text/html}, res['Content-Type']
    assert_equal five_hundred_body, res.body
    assert_nil res['Status']
  end

  def teardown
    return if @start_pid != $$

    if @pid
      Process.kill(:QUIT, @pid)
      pid2, status = Process.waitpid2(@pid)
      assert status.success?
    end

    Dir.chdir(@pwd)
    FileUtils.rmtree(@tmpdir)
    loop do
      Process.kill('-QUIT', 0)
      begin
        Process.waitpid(-1, Process::WNOHANG) or break
      rescue Errno::ECHILD
        break
      end
    end
  end

end if do_test
