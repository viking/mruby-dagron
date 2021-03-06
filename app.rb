module Dagron
  class Server
    attr_reader :apps

    def initialize(ip, port, server_name = nil)
      @ip = ip
      @port = port
      @server_name = server_name
      @apps = []
    end

    def register(path, app)
      @apps << [path, app]
    end

    def run
      parser = HTTP::Parser.new()
      socket = UV::TCP.new()
      socket.bind(UV::ip4_addr(@ip, @port))
      server = self
      socket.listen(1024) do |status|
        return if status != 0

        conn = socket.accept()
        request_buf = nil
        conn.read_start do |buf|
          if buf
            if request_buf
              request_buf += buf
            else
              request_buf = buf
            end
            request = parser.parse_request(request_buf)
            ok = true
            if request.headers['Content-Length']
              len = request.headers['Content-Length'].to_i
              ok = request.body && request.body.size >= len
            end

            if ok
              request_buf = nil

              # Find application
              app = nil
              script_name = nil
              path_info = nil
              server.apps.each do |entry|
                len = entry[0].length
                if request.path[0, len] == entry[0]
                  app = entry[1]
                  script_name = entry[0]
                  path_info = request.path[len..-1]
                  break
                end
              end

              # Respond
              status, headers, body =
                if app
                  sockname = conn.getsockname
                  env = {
                    'REQUEST_METHOD' => request.method,
                    'SCRIPT_NAME' => script_name,
                    'PATH_INFO' => path_info,
                    'QUERY_STRING' => request.query,
                    'SERVER_NAME' => @server_name ? @server_name : sockname.sin_addr,
                    'SERVER_PORT' => sockname.sin_port,
                    'HTTP_HOST' => request.headers['Host'],
                    'params' => server.params(request)
                  }
                  #p env
                  app.call(env)
                else
                  [ 404, nil, "Not found" ]
                end
              #puts "Status: #{status.inspect}, Headers: #{headers.inspect}, Body: #{body.inspect}"
              headers ||= {}
              close = false

              if !request.headers.has_key?('Connection') || request.headers['Connection'] != 'Keep-Alive'
                headers['Connection'] = 'close'
                close = true
              end
              headers['Content-Length'] = body.size

              data = "HTTP/1.1 #{status} #{server.reason_phrase(status)}\r\n"
              headers.each do |key, value|
                data += "#{key}: #{value}\r\n"
              end
              data += "\r\n#{body}"

              conn.write(data) do |status|
                if close
                  conn.close() if conn
                  conn = nil
                end
              end
            end
          end
        end
      end

      timer = UV::Timer.new
      timer.start(3000, 3000) do |status|
        UV::gc()
        GC.start
      end

      UV::run()
    end

    def find_app(path)
      app = nil
      @apps.each do |entry|
        len = entry[0].length
        if path[0, len] == entry[0]
          app = entry[1]
          break
        end
      end
      app
    end

    def reason_phrase(status)
      case status
      when 100 then "Continue"
      when 101 then "Switching Protocols"
      when 200 then "OK"
      when 201 then "Created"
      when 202 then "Accepted"
      when 203 then "Non-Authoritative Information"
      when 204 then "No Content"
      when 205 then "Reset Content"
      when 206 then "Partial Content"
      when 300 then "Multiple Choices"
      when 301 then "Moved Permanently"
      when 302 then "Found"
      when 303 then "See Other"
      when 304 then "Not Modified"
      when 305 then "Use Proxy"
      when 307 then "Temporary Redirect"
      when 400 then "Bad Request"
      when 401 then "Unauthorized"
      when 402 then "Payment Required"
      when 403 then "Forbidden"
      when 404 then "Not Found"
      when 405 then "Method Not Allowed"
      when 406 then "Not Acceptable"
      when 407 then "Proxy Authentication Required"
      when 408 then "Request Time-out"
      when 409 then "Conflict"
      when 410 then "Gone"
      when 411 then "Length Required"
      when 412 then "Precondition Failed"
      when 413 then "Request Entity Too Large"
      when 414 then "Request-URI Too Large"
      when 415 then "Unsupported Media Type"
      when 416 then "Requested range not satisfiable"
      when 417 then "Expectation Failed"
      when 500 then "Internal Server Error"
      when 501 then "Not Implemented"
      when 502 then "Bad Gateway"
      when 503 then "Service Unavailable"
      when 504 then "Gateway Time-out"
      when 505 then "HTTP Version not supported"
      end
    end

    def params(request)
      result = []
      if request.method == "GET"
        if request.query
          request.query.split("&").each do |segment|
            key, value = segment.split("=", 2)
            result.push({:name => key, :value => value})
          end
        end
      elsif request.method == "POST"
        if request.headers.has_key?('Content-Type')
          type, options = request.headers['Content-Type'].split(";", 2)
          if type == "multipart/form-data" && options
            boundary = nil
            options.split(";").each do |parameter|
              key, value = parameter.split("=", 2)
              if key.strip == "boundary"
                boundary = "--" + value
                break
              end
            end
            if boundary
              index = request.body.index(boundary)
              while index
                lower = index + boundary.length
                upper = request.body.index(boundary, lower)
                break if upper.nil?

                part = request.body[lower...upper]
                if part[0..1] == "\r\n"
                  parse_result = parse_part(part)
                  if parse_result
                    result.push(parse_result)
                  else
                    break
                  end
                else
                  break
                end

                index = upper
              end
            end
          end
        end
      end
      result
    end

    def parse_part(part)
      type = nil
      result = {}
      index = part.index("\r\n")
      while index
        lower = index + 2
        upper = part.index("\r\n", lower)
        break if upper.nil?

        if lower == upper
          lower = upper + 2
          upper = part.index("\r\n", lower)
          upper = upper.nil? ? -1 : upper - 1
          data = part[lower..upper]

          #case type
          #when nil
            #result[:value] = data
          #when "application/octet-stream"
            #result[:value] = Base64.decode(data)
          #end
          result[:value] = data
          break
        else
          line = part[lower...upper]
          key, value = line.split(": ", 2)
          case key
          when "Content-Disposition"
            disp, parameters = value.split("; ", 2)
            break if disp != "form-data"
            parameters.split("; ").each do |parameter|
              key, value = parameter.split("=", 2)
              if value[0] == '"' && value[-1] == '"'
                value = value[1..-2]
              end

              case key
              when "name"
                result[:name] = value
              when "filename"
                result[:filename] = value
              end
            end
          when "Content-Type"
            type = value
          end
          index = upper
        end
      end

      if result.has_key?(:name) && result.has_key?(:value)
        return result
      end
      nil
    end
  end

  class Image
    attr_reader :source, :width, :height, :errors

    def initialize
      @errors = []
    end

    def process(element)
      if element.name != "image"
        @errors << "element wasn't image"
        return false
      end

      @source = element.attribute("source")
      begin
        @width = element.int_attribute("width")
        @height = element.int_attribute("height")
      rescue RuntimeError
        @errors << "image element had invalid attributes"
      end

      @errors.empty?
    end
  end

  class Tileset
    attr_reader :name, :source, :firstgid, :tilewidth, :tileheight, :image, :errors
    def initialize
      @errors = []
    end

    def process(element)
      if element.name != "tileset"
        @errors << "element wasn't tileset"
        return false
      end

      @name = element.attribute("name")
      @source = element.attribute("source")
      begin
        @firstgid = element.int_attribute("firstgid")
        @tilewidth = element.int_attribute("tilewidth")
        @tileheight = element.int_attribute("tileheight")
      rescue RuntimeError
        @errors << "tileset element had invalid attributes"
      end

      if @source
        # TODO: handle case when source exists instead of name
      end

      @image = nil

      child = element.first_child_element
      while child
        if child.name == "image"
          if @image
            @errors << "tileset had multiple images"
          else
            @image = Image.new
            if !@image.process(child)
              @errors << "image was invalid"
            end
          end
        end
        child = child.next_sibling_element
      end

      if @image.nil?
        @errors << "tileset didn't have an image"
      end

      @errors.empty?
    end
  end

  class Layer
    attr_reader :name, :width, :height
    def initialize
      @errors = []
    end

    def process(element)
      if element.name != "layer"
        @errors << "element wasn't a layer"
        return false
      end

      @name = element.attribute('name')
      begin
        @width = element.int_attribute("width")
        @height = element.int_attribute("height")
      rescue RuntimeError
        @errors << "layer element had invalid attributes"
      end

      @errors.empty?
    end
  end

  class Map
    attr_reader :width, :height, :tilewidth, :tileheight, :tilesets, :layers, :errors

    def initialize
      @errors = []
    end

    def parse(data)
      doc = TinyXML2::XMLDocument.new
      if doc.parse(data) != :XML_SUCCESS
        @errors << "xml parsing error"
        return false
      end

      process(doc.root_element)
    end

    def process(element)
      if element.name != "map"
        @errors << "element wasn't map"
        return false
      end

      if element.attribute("orientation") != "orthogonal"
        @errors << 'expected map orientation attribute to be "orthogonal"'
      end

      begin
        @width = element.int_attribute("width")
        @height = element.int_attribute("height")
        @tilewidth = element.int_attribute("tilewidth")
        @tileheight = element.int_attribute("tileheight")
      rescue RuntimeError
        @errors << "map element had invalid attributes"
      end

      @tilesets = []
      @layers = []

      child = element.first_child_element
      while child
        case child.name
        when 'tileset'
          tileset = Tileset.new
          @tilesets << tileset
          if !tileset.process(child)
            @errors << "tileset #{@tilesets.length} was invalid"
          end
        when 'layer'
          layer = Layer.new
          @layers << layer
          if !layer.process(child)
            @errors << "layer #{@layers.length} was invalid"
          end
        end
        child = child.next_sibling_element
      end

      if @tilesets.empty?
        @errors << "map had no tilesets"
      end
      if @layers.empty?
        @errors << "map had no layers"
      end

      @errors.empty?
    end
  end

  class App
    DB_VERSION = 1

    def initialize(root, options = {})
      @root = root

      # read index
      if options[:environment] == 'production'
        f = UV::FS.open("#{@root}/views/index.html", UV::FS::O_RDONLY, UV::FS::S_IREAD)
        @index = f.read
        f.close
      end

      @db = SQLite3::Database.new("#{root}/dagron.db")
      migrate!
    end

    def migrate!
      version = 0
      begin
        @db.execute("SELECT version FROM schema_info") do |row, fields|
          version = row[0]
        end
      rescue RuntimeError
      end

      while version < DB_VERSION
        case version
        when 0
          @db.execute_batch("CREATE TABLE schema_info (version INTEGER)")
          @db.execute_batch("CREATE TABLE maps (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, width INTEGER, height INTEGER, tilewidth INTEGER, tileheight INTEGER, data BLOB, filename TEXT)")
          @db.execute_batch("CREATE TABLE images (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, width INTEGER, height INTEGER, data BLOB, filename TEXT)")
        end
        version += 1
        @db.execute_batch("DELETE FROM schema_info; INSERT INTO schema_info VALUES (#{version})")
      end
    end

    def index(env)
      if @index
        body = @index
      else
        f = UV::FS.open("#{@root}/views/index.html", UV::FS::O_RDONLY, UV::FS::S_IREAD)
        body = f.read
        f.close
      end
      [200, {'Content-Type' => 'text/html'}, body]
    end

    def maps(env)
      maps = []
      @db.execute('SELECT id, name, width, height, tilewidth, tileheight FROM maps') do |row, fields|
        hash = {}
        fields.each_with_index do |field, i|
          hash[field] = row[i]
        end
        maps << hash
      end
      body = JSON.stringify(maps)
      [200, {'Content-Type' => 'application/json'}, body]
    end

    def create_map(env)
      name = nil
      data = nil
      filename = nil
      env['params'].each do |param|
        if param[:name] == "map[name]"
          name = param[:value]
        elsif param[:name] == "map[file]" && param[:filename]
          data = param[:value]
          filename = param[:filename]
        end
      end

      errors = []
      errors.push("name is required") if name.nil?
      errors.push("file is required") if data.nil?

      if errors.empty?
        map = Map.new
        if map.parse(data)
          begin
            @db.execute_batch('INSERT INTO maps (name, width, height, tilewidth, tileheight, data, filename) VALUES(?, ?, ?, ?, ?, ?, ?)', name, map.width, map.height, map.tilewidth, map.tileheight, data, filename)
          rescue Exception => e
            errors.push(e.message)
          end
        else
          errors.push("map errors: #{map.errors.join(";")}")
        end
      end

      result =
        if errors.empty?
          { 'success' => true }
        else
          { 'success' => false, 'errors' => errors }
        end

      [200, {'Content-Type' => "application/json"}, JSON.stringify(result)]
    end

    def serve(env)
      path = env["PATH_INFO"]

      # Ensure there's no trickery
      filename = []
      parts = path[7..-1].split("/")
      parts.each do |part|
        if part == ".."
          if filename.empty?
            return app.not_found
          end
          filename.pop
        else
          filename.push(part)
        end
      end
      filename = filename.join("/")

      type =
        case filename.split('.')[-1]
        when 'css'
          "text/css"
        when 'js'
          "text/javascript"
        else
          "text/plain"
        end

      f = nil
      body = ""
      begin
        f = UV::FS.open("#{@root}/static/#{filename}", UV::FS::O_RDONLY, UV::FS::S_IREAD)
      rescue RuntimeError => e
        return not_found
      end

      begin
        loop do
          data = f.read(4096, body.size)
          if data.size > 0
            body += data
          else
            break
          end
        end
        result = [200, {'Content-Type' => type}, body]
      ensure
        f.close if f
      end
      result
    end

    def call(env)
      app = self
      path = env['PATH_INFO']
      if path[0] == '/'
        path = path[1..-1]
      end

      result =
        if path == ""
          index(env)
        elsif path == "maps"
          if env['REQUEST_METHOD'] == 'POST'
            create_map(env)
          else
            maps(env)
          end
        elsif path[0..6] == "static/"
          serve(env)
        end

      if result
        return result
      else
        return not_found
      end
    end

    def not_found
      [404, {'Content-Type' => 'text/plain'}, 'Not found']
    end
  end
end

server = Dagron::Server.new("127.0.0.1", 8888)
server.register("/", Dagron::App.new(ARGV[0]))
server.run
