require 'json'
require 'net/http'
require 'uri'

def format_finds(finds)
  finds.split("\n").map(&:strip)
end

def match_lines(row)
  matches = row.match(/\+(\d+)(?:,(\d+))?/).to_a[1..-1].map(&:to_i)
  matches.then do |(match_start, match_end)|
    (match_start..(match_start + match_end)).to_a
  end
end

def clear_hierarchy(hierarchy, indentation)
  hierarchy.delete_if { |k, _v| k >= indentation }
end

def hierarchy_contents(hierarchy, indentation)
  hierarchy.select { |k, _v| k < indentation }.flat_map { |k, v| v }
end

def main(token)
  # Check all changed files in this PR, against master
  # XXX: not 100% proof when you PR against a different branch, but it's fine for now
  filepaths = format_finds(`git diff --name-only origin/master`)

  haml_partials = filepaths.select do |filepath|
    filepath.include?('app/views') && filepath.split('/').last.start_with?('_') && filepath.end_with?('.haml')
  end

  reverse_containers = []

  haml_partials.each do |filepath|
    # For each haml partial, I want to find where it's used
    # - either in the same folder using the filename
    # - or in a superfolder using a part of the name
    # - or anywhere, using the full path

    file_parts = filepath.split('/')[2..-1]
    filename = file_parts.last[1..-6] # Strip _ and .haml
    dirs = file_parts[0..-2]

    containing_files = []
    (0...dirs.size).each do |dir_index|
      next_dir = dirs[0...(dirs.size - dir_index)].join('/')
      next_filename = (dirs[(dirs.size - dir_index)..-1] + [filename]).join('/')
      matches = format_finds(`find "app/views/#{next_dir}" -maxdepth 1 -name "*.haml" -exec grep -l "=\s*render\s\\+partial:\s*[\\"']#{next_filename}[\\"']" {} + | xargs -I{} grep -l "[-=]\s*cache\s\\+" {}`)
      matches += format_finds(`find "app/views/#{next_dir}" -maxdepth 1 -name "*.haml" -exec grep -l "=\s*render\s\\+layout:\s*[\\"']#{next_filename}[\\"']" {} + | xargs -I{} grep -l "[-=]\s*cache\s\\+" {}`)
      containing_files += matches.map { |match| [match, next_filename] }
    end

    next_filename = (dirs + [filename]).join('/')
    matches = format_finds(`find "app/views" -name "*.haml" -exec grep -l "=\s*render\s\\+partial:\s*[\\"']#{next_filename}[\\"']" {} + | xargs -I{} grep -l "[-=]\s*cache\s\\+" {}`)
    matches += format_finds(`find "app/views" -name "*.haml" -exec grep -l "=\s*render\s\\+layout:\s*[\\"']#{next_filename}[\\"']" {} + | xargs -I{} grep -l "[-=]\s*cache\s\\+" {}`)

    containing_files += matches.map { |match| [match, next_filename] }

    reverse_containers += containing_files.group_by { |containing_file, _long_filename| containing_file }.map { |k, v| [k, v.map { |r| r[1] }] }
  end

  required_line_changes = {}

  reverse_containers.each do |containing_file, filenames|
    last_indentation = 0
    variables_hierarchy = {}
    cache_hierarchy = {}
    covered_partials = []

    File.foreach(containing_file).with_index(1) do |line, line_num|
      # I need to check if the - cached line contains a variable or not, and
      # if the render partial: line contains cached: -> with a variable, or not
      # cached: ->.*\s+\{\s+\[

      next if line.empty? || /\A[[:space:]]*\z/.match(line)

      # Section 1 - extract stuff
      indentation = line.index(/[^ ]/)

      variable = line.match(/^\s*-\s*(@?\w+)\s*=/).to_a&.[](1)

      inline_cache_line = line.match(/\s*[-=]\s*cache\s*(?:\[[':]|%)/)
      variable_cache_line = line.match(/^\s*[-=]\s*cache\s+\["\w*#\{(\w+)\}/).to_a&.[](1)

      # Only check cached line in render partial: lines
      partial_string = line.match(/=\s*render\s+(?:partial|layout):\s*["']([\w\/]+)["']/).to_a&.[](1)

      inline_cached_line = line.match(/cached:\s+->\s*\(\w+\)\s+\{\s+\[['":]/)
      variable_cached_line = line.match(/cached:\s+->\s*\(\w+\)\s+\{\s+\[([^'":]\w+)/).to_a&.[](1)

      # Section 2 - clear hierarchies
      if last_indentation > indentation
        clear_hierarchy(variables_hierarchy, indentation + 1)
        clear_hierarchy(cache_hierarchy, indentation)
      end

      # Section 3 - update hierarchies
      if variable
        unless variables_hierarchy.key?(indentation)
          variables_hierarchy[indentation] = []
        end

        variables_hierarchy[indentation] << [variable, line_num]
      end

      if inline_cache_line
        cache_hierarchy[indentation] = line_num
      end

      current_variables = hierarchy_contents(variables_hierarchy, indentation + 1)
      if variable_cache_line
        if (replacing_variable = current_variables.find { |variable, _line_num| variable == variable_cache_line })
          cache_hierarchy[indentation] = replacing_variable[1]
        else
          raise "[#{containing_file}] Didn't find #{variable_cache_line} for cache in line #{line_num}, that sucks"
        end
      end

      # Section 4 - check for partials
      if partial_string
        applying_lines = hierarchy_contents(cache_hierarchy, indentation)

        if inline_cached_line
          applying_lines << inline_cached_line
        end

        if variable_cached_line
          if (replacing_variable = current_variables.find { |variable, _line_num| variable == variable_cached_line })
            applying_lines << replacing_variable[1]
          else
            raise "[#{containing_file}] Didn't find #{variable_cached_line} for cache in line #{line_num}, that sucks"
          end
        end

        if !applying_lines.empty? && filenames.include?(partial_string)
          covered_partials << [partial_string, line_num, applying_lines]
        end
      end

      # Section 5 - set last_indentation
      last_indentation = indentation
    end

    required_line_changes[containing_file] = covered_partials
  end

  all_containing_files = required_line_changes.keys.flatten.uniq

  changed_lines = all_containing_files.map do |containing_file|
    finds = format_finds(`git diff -U0 origin/master... #{containing_file} | grep "@@"`)
    [containing_file, finds.map { |row| match_lines(row) }.flatten.uniq]
  end.to_h

  missing_changes = []

  all_containing_files.each do |containing_file|
    file_changed_lines = changed_lines[containing_file]
    # TODO: Add group_by _partial_line for a better message
    required_line_changes[containing_file].each do |partial, _partial_line, partial_cache_lines|
      nonchanged_cache_lines = partial_cache_lines - file_changed_lines

      unless nonchanged_cache_lines.empty?
        missing_changes << [containing_file, partial, nonchanged_cache_lines.join(',')]
      end
    end
  end

  event_file = JSON.parse(File.open(ENV['GITHUB_EVENT_PATH']).read)
  comments_url = event_file['pull_request']['comments_url']

  missing_changes.uniq.each do |containing_file, partial, missing_line_changes|
    message = "Oh noes! You omitted to change cache in file #{containing_file} at lines [#{missing_line_changes}]. This message was generated because you changed the partial '#{partial}'."

    uri = URI.parse(comments_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    response = http.post(uri.path, JSON.dump({ body: message }), { 'Content-Type' => 'application/json', 'Accept' => 'application/json', 'Authorization' => "Bearer #{token}" })

    p response
  end

  nil
end

main ARGV[0]

