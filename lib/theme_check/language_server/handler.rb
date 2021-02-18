# frozen_string_literal: true

module ThemeCheck
  module LanguageServer
    TEXT_DOCUMENT_SYNC_FULL = 1

    class Handler
      CAPABILITIES = {
        completionProvider: {
          triggerCharacters: ['.', '{{ ', '{% '],
          context: true,
        },
        textDocumentSync: {
          openClose: true,
          change: TEXT_DOCUMENT_SYNC_FULL,
        },
      }

      def initialize(server)
        @server = server
        @previously_reported_files = Set.new
        @storage = InMemoryStorage.new
        @completion_engine = CompletionEngine.new(@storage)
      end

      def on_initialize(id, params)
        @root_path = params["rootPath"]
        # https://microsoft.github.io/language-server-protocol/specifications/specification-current/#responseMessage
        send_response(
          id: id,
          result: {
            capabilities: CAPABILITIES,
          }
        )
      end

      def on_exit(_id, _params)
        close!
      end
      alias_method :on_shutdown, :on_exit

      def on_text_document_did_change(_id, params)
        uri = text_document_uri(params)
        @storage.write(uri, did_change_text(params))
      end

      def on_text_document_did_close(_id, params)
        uri = text_document_uri(params)
        @storage.write(uri, nil)
      end

      def on_text_document_did_open(_id, params)
        uri = text_document_uri(params)
        @storage.write(uri, template(params))
        analyze_and_send_offenses(uri)
      end

      def on_text_document_did_save(_id, params)
        analyze_and_send_offenses(text_document_uri(params))
      end

      def on_text_document_completion(id, params)
        uri = text_document_uri(params)
        line = params.dig('position', 'line')
        col = params.dig('position', 'character')
        send_response(
          id: id,
          result: completions(uri, line, col)
        )
      end

      private

      def text_document_uri(params)
        params.dig('textDocument', 'uri').sub('file://', '')
      end

      def did_change_text(params)
        params.dig('contentChanges', 0, 'text')
      end

      def template(params)
        params.dig('textDocument', 'text')
      end

      def analyze_and_send_offenses(file_path)
        root = ThemeCheck::Config.find(file_path) || @root_path
        config = ThemeCheck::Config.from_path(root)
        storage = ThemeCheck::FileSystemStorage.new(
          config.root,
          ignored_patterns: config.ignored_patterns
        )
        theme = ThemeCheck::Theme.new(storage)

        offenses = analyze(theme, config)
        log("Found #{theme.all.size} templates, and #{offenses.size} offenses")
        send_diagnostics(offenses)
      end

      def analyze(theme, config)
        analyzer = ThemeCheck::Analyzer.new(theme, config.enabled_checks)
        log("Checking #{config.root}")
        analyzer.analyze_theme
        analyzer.offenses
      end

      def completions(uri, line, col)
        @completion_engine.completions(uri, line, col)
      end

      def send_diagnostics(offenses)
        reported_files = Set.new

        offenses.group_by(&:template).each do |template, template_offenses|
          next unless template
          send_diagnostic(template.path, template_offenses)
          reported_files << template.path
        end

        # Publish diagnostics with empty array if all issues on a previously reported template
        # have been solved.
        (@previously_reported_files - reported_files).each do |path|
          send_diagnostic(path, [])
        end

        @previously_reported_files = reported_files
      end

      def send_diagnostic(path, offenses)
        # https://microsoft.github.io/language-server-protocol/specifications/specification-current/#notificationMessage
        send_response(
          method: 'textDocument/publishDiagnostics',
          params: {
            uri: "file:#{path}",
            diagnostics: offenses.map { |offense| offense_to_diagnostic(offense) },
          },
        )
      end

      def offense_to_diagnostic(offense)
        {
          range: range(offense),
          severity: severity(offense),
          code: offense.code_name,
          source: "theme-check",
          message: offense.message,
        }
      end

      def severity(offense)
        case offense.severity
        when :error
          1
        when :suggestion
          2
        when :style
          3
        else
          4
        end
      end

      def range(offense)
        {
          start: {
            line: offense.start_line,
            character: offense.start_column,
          },
          end: {
            line: offense.end_line,
            character: offense.end_column,
          },
        }
      end

      def send_response(message)
        message[:jsonrpc] = '2.0'
        @server.send_response(message)
      end

      def log(message)
        @server.log(message)
      end

      def close!
        raise DoneStreaming
      end
    end
  end
end
