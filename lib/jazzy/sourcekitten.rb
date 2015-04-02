require 'json'
require 'pathname'

require 'jazzy/config'
require 'jazzy/executable'
require 'jazzy/highlighter'
require 'jazzy/source_declaration'
require 'jazzy/source_mark'

module Jazzy
  # This module interacts with the sourcekitten command-line executable
  module SourceKitten
    @documented_count = 0
    @undocumented_tokens = []

    # Group root-level docs by type and add as children to a group doc element
    def self.group_docs(docs, type)
      group, docs = docs.partition { |doc| doc.type == type }
      docs << SourceDeclaration.new.tap do |sd|
        sd.type     = SourceDeclaration::Type.overview
        sd.name     = type.plural_name
        sd.abstract = "The following #{type.plural_name.downcase} are " \
                      'available globally.'
        sd.children = group
      end if group.count > 0
      docs
    end

    # Generate doc URL by prepending its parents URLs
    # @return [Hash] input docs with URLs
    def self.make_doc_urls(docs, parents)
      docs.each do |doc|
        if doc.children.count > 0
          # Create HTML page for this doc if it has children
          parents_slash = parents.count > 0 ? '/' : ''
          doc.url = parents.join('/') + parents_slash + doc.name + '.html'
          doc.children = make_doc_urls(doc.children, parents + [doc.name])
        else
          # Don't create HTML page for this doc if it doesn't have children
          # Instead, make its link a hash-link on its parent's page
          id = doc.usr
          unless id
            id = doc.name || 'unknown'
            warn "`#{id}` has no USR. First make sure all modules used in " \
              'your project have been imported. If all used modules are ' \
              'imported, please report this by filing an issue at ' \
              'https://github.com/realm/jazzy/issues along with your Xcode ' \
              'project.'
          end
          doc.url = parents.join('/') + '.html#/' + id
        end
      end
    end

    def self.assert_xcode_location
      expected_xcode_select_path =
        Pathname('/Applications/Xcode-6p3-Beta4.app/Contents/Developer')
      return if xcode_developer_directory == expected_xcode_select_path
      raise 'Please install or symlink Xcode 6.3 in ' \
            "#{expected_xcode_select_path} and set as active developer " \
            'directory by running `sudo xcode-select -s ' \
            "#{expected_xcode_select_path}`"
    end

    def self.xcode_developer_directory
      dir = Pathname(`xcode-select -p`.chomp)
      dir.directory? ? dir.realpath : nil
    end

    def self.assert_swift_version
      swift_version = `xcrun swift --version` =~ /Swift version ([\d\.]+)/ &&
        Regexp.last_match[1]
      expected_swift_version = '1.2'
      return if swift_version == expected_swift_version
      raise "Jazzy only works with Swift #{expected_swift_version}."
    end

    # Run sourcekitten with given arguments and return STDOUT
    def self.run_sourcekitten(arguments)
      assert_xcode_location
      assert_swift_version
      bin_path = Pathname(__FILE__).parent + 'sourcekitten/sourcekitten'
      output, _ = Executable.execute_command(bin_path, arguments, true)
      output
    end

    def self.make_default_doc_info(declaration)
      # @todo: Fix these
      declaration.line = 0
      declaration.column = 0
      declaration.abstract = 'Undocumented'
      declaration.parameters = []
      declaration.children = []
    end

    def self.documented_child?(doc)
      return false unless doc['key.substructure']
      doc['key.substructure'].each do |child|
        return true if documented_child?(child)
      end
      false
    end

    def self.should_document?(doc)
      SourceDeclaration::AccessControlLevel.from_doc(doc) >= @min_acl
    end

    def self.process_undocumented_token(doc, declaration)
      source_directory = Config.instance.source_directory.to_s
      filepath = doc['key.filepath']
      if filepath && filepath.start_with?(source_directory)
        @undocumented_tokens << doc
      end
      return nil if !documented_child?(doc) && @skip_undocumented
      make_default_doc_info(declaration)
    end

    def self.make_paragraphs(doc, key)
      return nil unless doc[key]
      doc[key].map do |p|
        if p.keys.include?('Para')
          Jazzy.markdown.render(p['Para'])
        elsif p.keys.include?('Verbatim')
          Jazzy.markdown.render("```\n" + p['Verbatim'] + "```\n")
        else
          warn "Jazzy could not recognize the `#{p.keys.first}` tag. " \
               'Please report this by filing an issue at ' \
               'https://github.com/realm/jazzy/issues along with the comment ' \
               'including this tag.'
          Jazzy.markdown.render(p.values.first)
        end
      end.join
    end

    def self.make_doc_info(doc, declaration)
      return nil unless should_document?(doc)
      xml_key = 'key.doc.full_as_xml'
      return process_undocumented_token(doc, declaration) unless doc[xml_key]

      declaration.line = doc['key.doc.line']
      declaration.column = doc['key.doc.column']
      declaration.declaration = Highlighter.highlight(
        doc['key.parsed_declaration'] || doc['key.doc.declaration'],
        'swift',
      )
      declaration.parameters = []
      if doc['key.doc.parameters']
        declaration.parameters = doc['key.doc.parameters'].map do |p|
          {
            name: p['name'],
            discussion: make_paragraphs(p, 'discussion')
          }
        end
      end
      stripped_comment = string_until_first_rest_definition(
        doc['key.doc.comment'],
      )
      declaration.abstract = Jazzy.markdown.render(stripped_comment)
      declaration.discussion = ''
      declaration.return = make_paragraphs(doc, 'key.doc.result_discussion')

      return if doc['key.doc.comment'].to_s.include?(':nodoc:')

      @documented_count += 1
    end

    def self.string_until_first_rest_definition(string)
      matches = /^\s*:[^\s]+:/.match(string)
      return string unless matches
      string[0...matches.begin(0)]
    end

    def self.make_substructure(doc, declaration)
      if doc['key.substructure']
        declaration.children = make_source_declarations(
          doc['key.substructure'],
        )
      else
        declaration.children = []
      end
    end

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/CyclomaticComplexity
    def self.make_source_declarations(docs)
      declarations = []
      current_mark = SourceMark.new
      docs.each do |doc|
        if doc.key?('key.diagnostic_stage')
          declarations += make_source_declarations(doc['key.substructure'])
          next
        end
        declaration = SourceDeclaration.new
        declaration.type = SourceDeclaration::Type.new(doc['key.kind'])
        if declaration.type.mark? && doc['key.name'].start_with?('MARK: ')
          current_mark = SourceMark.new(doc['key.name'])
        end
        next unless declaration.type.should_document?

        unless declaration.type.name
          raise 'Please file an issue at ' \
                'https://github.com/realm/jazzy/issues about adding support ' \
                "for `#{declaration.type.kind}`."
        end

        declaration.file = doc['key.filepath']
        declaration.usr  = doc['key.usr']
        declaration.name = doc['key.name']
        declaration.mark = current_mark
        acl = SourceDeclaration::AccessControlLevel.new(
          doc['key.accessibility'],
        )
        declaration.access_control_level = acl
        declaration.start_line = doc['key.parsed_scope.start']
        declaration.end_line = doc['key.parsed_scope.end']

        next unless make_doc_info(doc, declaration)
        make_substructure(doc, declaration)
        declarations << declaration
      end
      declarations
    end
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength

    def self.doc_coverage
      return 0 if @documented_count == 0 && @undocumented_tokens.count == 0
      (100 * @documented_count) /
        (@undocumented_tokens.count + @documented_count)
    end

    def self.deduplicate_declarations(declarations)
      duplicates = declarations.group_by { |d| [d.usr, d.type.kind] }.values
      duplicates.map do |decls|
        decls.first.tap do |d|
          d.children = deduplicate_declarations(decls.flat_map(&:children).uniq)
        end
      end
    end

    # Parse sourcekitten STDOUT output as JSON
    # @return [Hash] structured docs
    def self.parse(sourcekitten_output, min_acl, skip_undocumented)
      @min_acl = min_acl
      @skip_undocumented = skip_undocumented
      sourcekitten_json = JSON.parse(sourcekitten_output)
      docs = make_source_declarations(sourcekitten_json)
      docs = deduplicate_declarations(docs)
      SourceDeclaration::Type.all.each do |type|
        docs = group_docs(docs, type)
      end
      [make_doc_urls(docs, []), doc_coverage, @undocumented_tokens]
    end
  end
end
