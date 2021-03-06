require 'daemons'
require 'logger'
begin
  require 'growl'
rescue LoadError
end

module Sheepsafe
  class Controller
    LOG_FILE = Sheepsafe::Config::FILE.sub(/\.yml/, '.log')

    def initialize(config = nil, network = nil, logger = nil)
      @config  = config  || Sheepsafe::Config.new
      @network = network || Sheepsafe::Network.new(@config)
      @logger  = logger  || begin
                              STDOUT.reopen(File.open(LOG_FILE, (File::WRONLY | File::APPEND)))
                              Logger.new(STDOUT)
                            end
    end

    def run
      if ARGV.first == 'proxy'  # 'sheepsafe proxy up/down/kick'
        bring_socks_proxy ARGV[1]
        return
      end

      log("Sheepsafe starting")
      if network_up?
        if network_changed?
          if switch_to_trusted?
            notify_ok "Switching to #{@config.trusted_location} location"
            system "scselect #{@config.trusted_location}"
            bring_socks_proxy 'down'
          elsif switch_to_untrusted?
            notified = false
            loop do
              require 'open-uri'
              length = open("http://example.com") {|f| f.meta['content-length'] } rescue nil
              break if length == "596" # successful contact w/ example.com
              notify_warning("Waiting for internet connection before switching") unless notified
              notified = true
              sleep 5
            end
            notify_warning "Switching to #{@config.untrusted_location} location"
            system "scselect #{@config.untrusted_location}"
            bring_socks_proxy 'up'
          end
          @config.last_network = @network
          @config.write
        elsif !@network.trustworthy?
          # recycle the proxy server on network changes
          bring_socks_proxy 'restart'
        end
      else
        log("AirPort is off")
      end
      log("Sheepsafe finished")
    end

    def network_up?
      @network.up?
    end

    def network_changed?
      @config.last_network.nil? || @network.ssid != @config.last_network.ssid || @network.bssid != @config.last_network.bssid
    end

    def switch_to_trusted?
      @network.trustworthy?
    end

    def switch_to_untrusted?
      !@network.trustworthy?
    end

    def bring_socks_proxy(direction)
      cmd = case direction
            when 'up'   then 'start'
            when 'down' then 'stop'
            when 'kick' then 'restart'
            else
              direction
            end
      Daemons.run_proc('.sheepsafe.proxy', :ARGV => [cmd], :dir_mode => :normal, :dir => ENV['HOME']) do
        pid = nil
        trap("TERM") do
          Process.kill("TERM", pid)
          exit 0
        end
        sleep 2                 # wait a bit before starting proxy
        loop do
          pid = fork do
            exec("ssh -p #{@config.ssh_port } -ND #{@config.socks_port} #{@config.ssh_host}")
          end
          Process.waitpid(pid)
          sleep 1
        end
      end
    end

    def proxy_running?
      File.exist?("#{ENV['HOME']}/.sheepsafe.proxy.pid") && File.read("#{ENV['HOME']}/.sheepsafe.proxy.pid").to_i > 0
    end

    def notify_ok(msg)
      when_growl_available { Growl.notify_ok(msg) }
      log(msg)
    end

    def notify_warning(msg)
      when_growl_available { Growl.notify_warning(msg) }
      log(msg)
    end

    def when_growl_available(&block)
      block.call if defined?(Growl)
    end

    def log(msg)
      @logger.info(msg)
    end
  end
end
