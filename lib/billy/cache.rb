require 'resolv'
require 'uri'
require 'yaml'
require 'billy/json_utils'
require 'singleton'

module Billy
  class Cache
    include Singleton

    attr_reader :scope

    def initialize
      reset
    end

    def cached?(method, url, body)
      # Only log the key the first time it's looked up (in this method)
      key = key(method, url, body, true)
      !@cache[key].nil? or persisted?(key)
    end

    def persisted?(key)
      Billy.config.persist_cache and File.exists?(cache_file(key))
    end

    def fetch(method, url, body)
      key = key(method, url, body)
      @cache[key] or fetch_from_persistence(key)
    end

    def fetch_from_persistence(key)
      begin
        @cache[key] = YAML.load(File.open(cache_file(key))) if persisted?(key)
      rescue ArgumentError => e
        Billy.log :error, "Could not parse YAML: #{e.message}"
        nil
      end
    end

    def store(method, url, request_headers, body, response_headers, status, content)
      cached = {
        :scope => scope,
        :url => format_url(url),
        :body => body,
        :status => status,
        :method => method,
        :headers => response_headers,
        :content => content
      }

      cached.merge!({:request_headers => request_headers}) if Billy.config.cache_request_headers

      key = key(method, url, body)
      @cache[key] = cached

      if Billy.config.persist_cache
        Dir.mkdir(Billy.config.cache_path) unless File.exists?(Billy.config.cache_path)

        begin
          File.open(cache_file(key), 'w') do |f|
            f.write(cached.to_yaml(:Encoding => :Utf8))
          end
        rescue StandardError => e
        end
      end
    end

    def reset
      @cache = {}
    end

    def key(method, orig_url, body, log_key = false)
      ignore_params = Billy.config.ignore_params.include?(format_url(orig_url, true))
      url = URI(format_url(orig_url, ignore_params))

      key =
        (Billy.config.key_generators[url.host] && Billy.config.key_generators[url.host].call(method, url, body)) ||
         default_key(method, url, body, ignore_params)

      Billy.log(:info, "puffing-billy: CACHE KEY for '#{orig_url}#{body_msg_for(body, method, ignore_params)}' is '#{key}'") if log_key

      key
    end

    def format_url(url, ignore_params=false, dynamic_jsonp=Billy.config.dynamic_jsonp)
      url = URI(url)
      port_to_include = Billy.config.ignore_cache_port ? '' : ":#{url.port}"
      formatted_url = url.scheme+'://'+url.host+port_to_include+url.path

      return formatted_url if ignore_params

      if url.query
        query_string = if dynamic_jsonp
                         query_hash = Rack::Utils.parse_query(url.query)
                         Billy.config.dynamic_jsonp_keys.each{|k| query_hash.delete(k) }
                         Rack::Utils.build_query(query_hash)
                       else
                         url.query
                       end

        formatted_url += "?#{query_string}"
      end

      formatted_url += '#'+url.fragment if url.fragment

      formatted_url
    end

    def cache_file(key)
      File.join(Billy.config.cache_path, "#{key}.yml")
    end

    def scope_to(new_scope = nil)
      self.scope = new_scope
    end

    def with_scope(use_scope = nil, &block)
      raise ArgumentError, 'Expected a block but none was received.' if block.nil?
      original_scope = scope
      scope_to use_scope
      block.call()
    ensure
      scope_to original_scope
    end

    def use_default_scope
      scope_to nil
    end

    private

    attr_writer :scope

    def default_key(method, url, body, ignore_params)
      key = method+'_'+url.host+'_'+Digest::SHA1.hexdigest(scope.to_s + url.to_s)
      if formatted_body_for(body, method, ignore_params)
        key += Digest::SHA1.hexdigest(formatted_body_for(body, method, ignore_params))
      end

      key
    end

    def body_msg_for body, method, ignore_params
      return nil if method != 'post' || ignore_params
      " with body '#{formatted_body_for(body, method, ignore_params)}'"
    end

    def formatted_body_for body, method, ignore_params
      return nil if method != 'post' || ignore_params
      JSONUtils::json?(body.to_s) ? JSONUtils::sort_json(body.to_s) : body.to_s
    end
  end
end
