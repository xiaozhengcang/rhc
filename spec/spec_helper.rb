require 'coverage_helper'
require 'webmock/rspec'
require 'fakefs/safe'
require 'rbconfig'

if ENV['PRY']
  require 'pry' 
  require 'pry-debugger'
end

# Environment reset
ENV['http_proxy'] = nil
ENV['HTTP_PROXY'] = nil
ENV['OPENSHIFT_CONFIG'] = nil

class FakeFS::Mode
  def initialize(mode_s)
    @s = mode_s
  end
  def to_s(*args)
    @s
  end
end
class FakeFS::Stat
  attr_reader :mode
  def initialize(mode_s)
    @mode = FakeFS::Mode.new(mode_s)
  end
end

# chmod isn't implemented in the released fakefs gem
# but is in git.  Once the git version is released we
# should remove this and actively check permissions
class FakeFS::File
  def self.chmod(*args)
    # noop
  end

  def self.stat(path)
    FakeFS::Stat.new(mode(path))
  end

  def self.mode(path)
    @modes && @modes[path] || '664'
  end
  def self.expect_mode(path, mode)
    (@modes ||= {})[path] = mode
  end

  # FakeFS incorrectly assigns this to '/'
  remove_const(:PATH_SEPARATOR) rescue nil
  const_set(:PATH_SEPARATOR, ":")
  const_set(:ALT_SEPARATOR, '') rescue nil

  def self.executable?(path)
    # if the file exists we will assume it is executable
    # for testing purposes
    self.exists?(path)
  end
end

IO.instance_eval{ alias :read_orig :read }

module FakeFS
  class << self
    alias_method :activate_orig, :activate!
    alias_method :deactivate_orig, :deactivate!

    def activate!
      IO.instance_eval{ def self.read(path); FakeFS::File.read(path); end }
      activate_orig
    end
    def deactivate!
      IO.instance_eval{ alias :read :read_orig }
      deactivate_orig
    end
  end
end

require 'rhc/cli'

class MockHighLineTerminal < HighLineExtension
  def self.use_color?
    true
  end

  def initialize(input=StringIO.new, output=StringIO.new)
    super
    @last_read_pos = 0
  end

  ##
  # read
  #
  # seeks to the last read in the IO stream and reads
  # the data from that position so we don't repeat
  # reads or get empty data due to writes moving
  # the caret to the end of the stream
  def read
    @output.seek(@last_read_pos)
    result = @output.read
    @last_read_pos = @output.pos
    result
  end

  ##
  # write_line
  #
  # writes a line of data to the end of the
  # input stream appending a newline so
  # highline knows to stop processing and then
  # resets the caret position to the last read
  def write_line(str)
    reset_pos = @input.pos
    # seek end so we don't overwrite anything
    @input.seek(0, IO::SEEK_END)
    result = @input.write "#{str}\n"
    @input.seek(reset_pos)
    result
  end
  def close_write
    @input.close_write
  end
end

include WebMock::API

require 'httpclient'
require 'webmock/http_lib_adapters/httpclient_adapter'
#
# Patched from WebMock 1.11, needs to be upstreamed
# 
class WebMockHTTPClient
  def do_get(req, proxy, conn, stream = false, &block)
    request_signature = build_request_signature(req, :reuse_existing)

    WebMock::RequestRegistry.instance.requested_signatures.put(request_signature)

    if webmock_responses[request_signature]
      webmock_response = webmock_responses.delete(request_signature)
      response = build_httpclient_response(webmock_response, stream, &block)
      @request_filter.each do |filter|
        # CHANGED
        r = filter.filter_response(req, response)
        res = do_get(req, proxy, conn, stream, &block) if r == :retry
        # END CHANGES
      end
      res = conn.push(response)
      WebMock::CallbackRegistry.invoke_callbacks(
        {:lib => :httpclient}, request_signature, webmock_response)
      res
    elsif WebMock.net_connect_allowed?(request_signature.uri)
      # in case there is a nil entry in the hash...
      webmock_responses.delete(request_signature)

      res = if stream
        do_get_stream_without_webmock(req, proxy, conn, &block)
      else
        do_get_block_without_webmock(req, proxy, conn, &block)
      end
      res = conn.pop
      conn.push(res)
      if WebMock::CallbackRegistry.any_callbacks?
        webmock_response = build_webmock_response(res)
        WebMock::CallbackRegistry.invoke_callbacks(
          {:lib => :httpclient, :real_request => true}, request_signature,
          webmock_response)
      end
      res
    else
      raise WebMock::NetConnectNotAllowedError.new(request_signature)
    end
  end
end

def stderr
  $stderr.rewind
  # some systems might redirect warnings to stderr
  [$stderr,$terminal].map(&:read).delete_if{|x| x.strip.empty?}.join(' ')
end

module Commander::UI
  alias :enable_paging_old :enable_paging
  def enable_paging
  end
end


module CommandExampleHelpers
  #
  # Allow this example to stub command methods
  # by guaranteeing the instance exists prior
  # to command execution.  Use with methods on
  # CommandHelpers
  #
  def using_command_instance
    subject{ described_class }
    let(:instance) { described_class.new }
  end
end
#
# Helper methods for executing commands and
# stubbing/mocking methods
#
module CommandHelpers
  def command_runner(*args)
    mock_terminal
    new_command_runner *args do
      instance #ensure instance is created before subject :new is mocked
      subject.stub(:new).and_return(instance)
      RHC::Commands.to_commander
    end
  end
  def run!(*args)
    command_runner(*args).run!
  end
  def expects_running(*args, &block)
    r = command_runner(*args)
    lambda { r.run! }
  end
  def command_for(*args)
    command = nil
    RHC::Commands.stub(:execute){ |cmd, method, args| command = cmd; 0 }
    command_runner(*args).run!
    command
  end

  #
  # These methods assume the example has declared
  # let(:arguments){ [<arguments>] }
  #

  def run_command(args=arguments)
    mock_terminal
    input.each { |i| $terminal.write_line(i) } if respond_to?(:input)
    $terminal.close_write
    run!(*args)
  end

  def command_output(args=arguments)
    run_command(args)
  rescue SystemExit => e
    "#{@output.string}\n#{$stderr.string}#{e}"
  else
    "#{@output.string}\n#{$stderr.string}"
  end

  #
  # These methods bypass normal command stubbing.
  # Should really be used when stubbing the whole
  # path.  Most specs should use run_instance.
  #
  def run(input=[])
    mock_terminal
    input.each { |i| $terminal.write_line(i) }
    $terminal.close_write
    RHC::CLI.start(arguments)
  end

  def run_output(input=[])
    run(input)
  rescue SystemExit => e
    "#{@output.string}\n#{$stderr.string}#{e}"
  else
    "#{@output.string}\n#{$stderr.string}"
  end

end

module ClassSpecHelpers

  include Commander::Delegates

  def const_for(obj=nil)
    if obj
      Object.const_set(const_for, obj)
    else
      "#{example.full_description}".split(" ").map{|word| word.capitalize}.join.gsub(/[^\w]/, '')
    end
  end

  def with_constants(constants, base=Object, &block)
    constants.each do |constant, val|
      base.const_set(constant, val)
    end

    block.call
  ensure
    constants.each do |constant, val|
      base.send(:remove_const, constant)
    end
  end

  def new_command_runner *args, &block
    Commander::Runner.instance_variable_set :"@singleton", RHC::CommandRunner.new(args)
    program :name, 'test'
    program :version, '1.2.3'
    program :description, 'something'
    program :help_formatter, RHC::HelpFormatter

    #create_test_command
    yield if block
    Commander::Runner.instance
  end

  def mock_terminal
    @input = StringIO.new
    @output = StringIO.new
    $stdout = @output
    $stderr = (@error = StringIO.new)
    $terminal = MockHighLineTerminal.new @input, @output
  end
  def input_line(s)
    $terminal.write_line s
  end
  def last_output(&block)
    if block_given?
      yield $terminal.read
    else
      $terminal.read
    end
  end

  def capture(&block)
    old_stdout = $stdout
    old_stderr = $stderr
    old_terminal = $terminal
    @input = StringIO.new
    @output = StringIO.new
    $stdout = @output
    $stderr = (@error = StringIO.new)
    $terminal = MockHighLineTerminal.new @input, @output
    yield
    @output.string
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
    $terminal = old_terminal
  end

  def capture_all(&block)
    old_stdout = $stdout
    old_stderr = $stderr
    old_terminal = $terminal
    @input = StringIO.new
    @output = StringIO.new
    $stdout = @output
    $stderr = @output
    $terminal = MockHighLineTerminal.new @input, @output
    yield
    @output.string
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
    $terminal = old_terminal
  end

  #
  # usage: stub_request(...).with(&user_agent_header)
  #
  def user_agent_header
    lambda do |request|
      #User-Agent is not sent to mock by httpclient
      #request.headers['User-Agent'] =~ %r{\Arhc/\d+\.\d+.\d+ \(.*?ruby.*?\)}
      true
    end
  end

  def base_config(&block)
    config = RHC::Config.new
    config.stub(:load_config_files)
    config.stub(:load_servers)
    defaults = config.instance_variable_get(:@defaults)
    yield config, defaults if block_given?
    RHC::Config.stub(:default).and_return(config)
    RHC::Config.stub(:new).and_return(config)
    config
  end

  def user_config
    user = respond_to?(:username) ? self.username : 'test_user'
    password = respond_to?(:password) ? self.password : 'test pass'
    server = respond_to?(:server) ? self.server : nil

    base_config do |config, defaults|
      defaults.add 'default_rhlogin', user
      defaults.add 'password', password
      defaults.add 'libra_server', server if server
    end.tap do |c|
      opts = c.to_options
      opts[:rhlogin].should == user
      opts[:password].should == password
      opts[:server].should == server if server
    end
  end

  def local_config
    user = respond_to?(:local_config_username) ? self.local_config_username : 'test_user'
    password = respond_to?(:local_config_password) ? self.local_config_password : 'test pass'
    server = respond_to?(:local_config_server) ? self.local_config_server : nil

    c = base_config

    local_config = RHC::Vendor::ParseConfig.new
    local_config.add('default_rhlogin', user) if user
    local_config.add('password', password) if password
    local_config.add('libra_server', server) if server
    
    c.instance_variable_set(:@local_config, local_config)
    c.instance_variable_set(:@servers, RHC::Servers.new)
    opts = c.to_options
    opts[:rhlogin].should == user
    opts[:password].should == password
    opts[:server].should == server if server
  end

  def expect_multi_ssh(command, hosts, check_error=false)
    require 'net/ssh/multi'

    session = double('Multi::SSH::Session')
    described_class.any_instance.stub(:requires_ssh_multi!)
    channels = hosts.inject({}) do |h, (k,v)| 
      c = double(:properties => {}, :connection => double(:properties => {}))
      h[k] = c
      h
    end
    session.should_receive(:use).exactly(hosts.count).times.with do |host, opts|
      opts[:properties].should_not be_nil
      opts[:properties][:gear].should_not be_nil
      hosts.should have_key(host)
      channels[host].connection.properties.merge!(opts[:properties])
      true
    end
    session.stub(:_command).and_return(command)
    session.stub(:_hosts).and_return(hosts)
    session.stub(:_channels).and_return(channels)
    session.instance_eval do
      def exec(arg1, *args, &block)
        arg1.should == _command
        _hosts.to_a.sort{ |a,b| a[0] <=> b[0] }.each do |(k,v)|
          block.call(_channels[k], :stdout, v)
        end
      end
    end
    session.should_receive(:loop) unless hosts.empty?
    Net::SSH::Multi.should_receive(:start).and_yield(session).with do |opts|
      opts.should have_key(:on_error)
      capture_all{ opts[:on_error].call('test') }.should =~ /Unable to connect to gear test/ if check_error
      true
    end
    session
  end  
end

module ExitCodeMatchers
  RSpec::Matchers.define :exit_with_code do |code|
    actual = nil
    match do |block|
      begin
        actual = block.call
      rescue SystemExit => e
        actual = e.status
      end
      actual and actual == code
    end
    failure_message_for_should do |block|
      "expected block to call exit(#{code}) but exit" +
        (actual.nil? ? " not called" : "(#{actual}) was called")
    end
    failure_message_for_should_not do |block|
      "expected block not to call exit(#{code})"
    end
    description do
      "expect block to call exit(#{code})"
    end
  end
end

module CommanderInvocationMatchers
  InvocationMatch = Class.new(RuntimeError)

  RSpec::Matchers.define :call do |method|
    chain :on do |object|
      @object = object
    end
    chain :with do |*args|
      @args = args
    end
    chain :and_stop do
      @stop = true
    end

    match do |block|
      e = @object.should_receive(method)
      e.and_raise(InvocationMatch) if @stop
      e.with(*@args) if @args
      begin
        block.call
        true
      rescue InvocationMatch => e
        true
      rescue SystemExit => e
        false
      end
    end
    description do
      "expect block to invoke '#{method}' on #{@object} with #{@args}"
    end
  end

  RSpec::Matchers.define :not_call do |method|
    chain :on do |object|
      @object = object
    end
    chain :with do |*args|
      @args = args
    end

    match do |block|
      e = @object.should_not_receive(method)
      e.with(*@args) if @args
      begin
        block.call
        true
      rescue SystemExit => e
        false
      end
    end
    description do
      "expect block to invoke '#{method}' on #{@object} with #{@args}"
    end
  end  
end

module ColorMatchers
  COLORS = {
    :green => 32,
    :yellow => 33,
    :cyan => 36,
    :red => 31,
    :clear => 0
  }

  RSpec::Matchers.define :be_colorized do |msg,color|
    match do |actual|
      actual == colorized_message(msg,color)
    end

    failure_message_for_should do |actual|
      failure_message(actual,msg,color)
    end

    failure_message_for_should_not do |actual|
      failure_message(actual,msg,color)
    end

    def failure_message(actual,msg,color)
      "expected: #{colorized_message(msg,color).inspect}\n" +
      "     got: #{actual.inspect}"
    end

    def ansi_code(color)
      "\e[#{ColorMatchers::COLORS[color]}m"
    end

    def colorized_message(msg,color)
      [
        ansi_code(color),
        msg,
        ansi_code(:clear),
        "\n"
      ].join('')
    end
  end
end

def mac?
  RbConfig::CONFIG['host_os'] =~ /^darwin/
end

def mock_save_snapshot_file(app)
  @ssh_uri = URI.parse app.ssh_url
  mock_popen3("ssh #{@ssh_uri.user}@#{@ssh_uri.host} 'snapshot' > #{@app.name}.tar.gz", nil,
              "Pulling down a snapshot of application '#{app.name}' to #{app.name}.tar.gz", nil)
end

def mock_restore_snapshot_file(app)
  @ssh_uri = URI.parse app.ssh_url
  File.stub(:exists?).and_return(true)
  RHC::TarGz.stub(:contains).and_return(true)
  in_mock, out_mock, err_mock = 
    mock_popen3("ssh #{@ssh_uri.user}@#{@ssh_uri.host} 'restore INCLUDE_GIT'", nil, "Restoring from snapshot #{app.name}.tar.gz to application '#{app.name}'", nil)
  lines = ''
  File.open(File.expand_path('../rhc/assets/targz_sample.tar.gz', __FILE__), 'rb') do |file|
    file.chunk(4096) do |chunk|
      lines << chunk
    end
  end
  in_mock.stub(:write)
  in_mock.stub(:close_write)
end

def mock_popen3(cmd, std_in, std_out, std_err)
  in_mock = double('std in')
  out_mock = double('std out')
  err_mock = double('std err')
  in_mock.stub(:gets).and_return(std_in)      
  out_mock.stub(:gets).and_return(std_out)      
  err_mock.stub(:gets).and_return(std_err)      
  Open3.stub(:popen3)
  Open3.should_receive(:popen3).with(cmd).and_yield(in_mock, out_mock, err_mock)
  return in_mock, out_mock, err_mock
end


RSpec.configure do |config|
  config.include(ExitCodeMatchers)
  config.include(CommanderInvocationMatchers)
  config.include(ColorMatchers)
  config.include(ClassSpecHelpers)
  config.include(CommandHelpers)
  config.extend(CommandExampleHelpers)
  config.backtrace_clean_patterns = [] if ENV['FULL_BACKTRACE']
end

module TestEnv
  extend ClassSpecHelpers
  class << self
    attr_accessor :instance, :subject
    def instance=(i)
      self.subject = i.class
      @instance = i
    end
  end
end
