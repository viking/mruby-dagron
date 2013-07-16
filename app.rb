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
        conn.read_start do |buf|
          if buf
            request = parser.parse_request(buf)

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
                  'HTTP_HOST' => request.headers['Host']
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
  end

  class App
    DB_VERSION = 1
    INDEX_VIEW = '<!DOCTYPE html>
<html lang="en">

<head>
  <meta charset="utf-8">
  <title>Dagron</title>
  <script type="text/javascript" src="static/underscore-min.js"></script>
  <script type="text/javascript" src="static/backbone-min.js"></script>
</head>

<body>
sup?
</body>
</html>'

    def initialize(root)
      @root = root
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
          @db.execute_batch("CREATE TABLE schema_info (version INT)")
          @db.execute_batch("CREATE TABLE maps (id INT PRIMARY KEY, name TEXT, data BLOB)")
          @db.execute_batch("CREATE TABLE images (id INT PRIMARY KEY, name TEXT, data BLOB)")
        end
        version += 1
        @db.execute_batch("DELETE FROM schema_info; INSERT INTO schema_info VALUES (#{version})")
      end
    end

    def call(env)
      app = self
      path = env['PATH_INFO']
      if path[0] == '/'
        path = path[1..-1]
      end

      result = nil
      if path == ""
        result = [200, {'Content-Type' => 'text/html'}, App::INDEX_VIEW]
      elsif path[0..6] == "static/"
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
