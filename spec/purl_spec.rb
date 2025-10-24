# frozen_string_literal: true

require 'json'
require 'rspec'

class PurlTestCase
  attr_reader :description, :test_type, :input, :expected_output, :expected_failure, :test_group

  def initialize(description:, test_type:, input:, expected_output: nil, expected_failure: false, test_group: nil)
    @description = description
    @test_type = test_type
    @input = input
    @expected_output = expected_output
    @expected_failure = expected_failure
    @test_group = test_group
  end
end

def load_test_case(case_hash)
  PurlTestCase.new(
    description: case_hash['description'],
    test_type: case_hash['test_type'],
    input: case_hash['input'],
    expected_output: case_hash['expected_output'],
    expected_failure: case_hash.fetch('expected_failure', false),
    test_group: case_hash['test_group']
  )
end

def load_spec_files(spec_dir)
  spec_data = {}
  Dir.children(spec_dir).each do |filename|
    next unless filename.end_with?('-test.json')

    filepath = File.join(spec_dir, filename)
    begin
      data = JSON.parse(File.read(filepath))
      spec_data[filename] = data['tests'].map { |tc| load_test_case(tc) }
    rescue JSON::ParserError => e
      warn "Error parsing #{filename}: #{e}"
    end
  end
  spec_data
end

RSpec.describe 'PackageURL specification tests' do
  current_dir = __dir__
  root_dir = File.expand_path('..', current_dir)
  spec_file_path = File.join(root_dir, 'purl-spec', 'tests', 'spec', 'specification-test.json')

  test_cases = JSON.parse(File.read(spec_file_path))
  all_tests = test_cases['tests'].map { |tc| load_test_case(tc) }

  parse_tests = all_tests.select { |t| t.test_type == 'parse' }
  build_tests = all_tests.select { |t| t.test_type == 'build' }

  # Load type files under spec/tests/types
  spec_dir = File.join(root_dir, 'purl-spec', 'tests', 'types')
  spec_dict = load_spec_files(spec_dir)

  flattened_cases = []
  spec_dict.each do |filename, cases|
    cases.each do |c|
      flattened_cases << [filename, c.description, c]
    end
  end

  # Helpers
  def run_test_case(test_case)
    case test_case.test_type
    when 'parse'
      purl = PackageURL.parse(test_case.input)
      expected = test_case.expected_output
      expect(purl.type).to eq(expected['type'])
      expected_namespace = expected['namespace']
      expect(purl.namespace).to eq(expected_namespace)

      expect(purl.name).to eq(expected['name'])
      expect(purl.version).to eq(expected['version'])

      if expected['qualifiers'] && !expected['qualifiers'].empty?
        expect(purl.qualifiers).to eq(expected['qualifiers'])
      else
        if purl.respond_to?(:qualifiers)
          q = purl.qualifiers
          if q.nil?
            expect(q).to be_nil
          else
            expect(q).to be_empty
          end
        end
      end

      expected_subpath = expected['subpath']
      expect(purl.subpath).to eq(expected_subpath)

    when 'roundtrip'
      purl = PackageURL.parse(test_case.input)
      expect(purl.to_s).to eq(test_case.expected_output)

    when 'build'
      inp = test_case.input
      purl = PackageURL.new(
        type: inp['type'],
        namespace: inp['namespace'],
        name: inp['name'],
        version: inp['version'],
        qualifiers: inp['qualifiers'],
        subpath: inp['subpath']
      )
      expect(purl.to_s).to eq(test_case.expected_output)

    when 'validation'
      test_group = test_case.test_group
      unless %w[base advanced].include?(test_group)
        raise "Unknown test group: #{test_group}"
      end
      strict = test_group == 'base'

      messages = PackageURL.validate_string(purl: test_case.input, strict: strict)
      messages_array = messages.map { |m| (m.respond_to?(:to_h) ? m.to_h : m) }

      if test_case.expected_output
        expect(messages_array).to eq(test_case.expected_output)
      else
        expect(messages_array).to be_empty
      end

    else
      raise "Unknown test type: #{test_case.test_type}"
    end
  end

  context 'parse tests' do
    parse_tests.each do |tc|
      it tc.description do
        if tc.expected_failure
          expect { PackageURL.parse(tc.input) }.to raise_error(StandardError)
        else
          result = PackageURL.parse(tc.input)
          expect(result.to_s).to eq(tc.expected_output)
        end
      end
    end
  end

  context 'build tests' do
    build_tests.each do |tc|
      it tc.description do
        kwargs = {
          type: tc.input['type'],
          namespace: tc.input['namespace'],
          name: tc.input['name'],
          version: tc.input['version'],
          qualifiers: tc.input['qualifiers'],
          subpath: tc.input['subpath']
        }

        if tc.expected_failure
          expect { PackageURL.new(**kwargs).to_s }.to raise_error(StandardError)
        else
          purl = PackageURL.new(**kwargs)
          expect(purl.to_s).to eq(tc.expected_output)
        end
      end
    end
  end

  context 'package type tests from spec/tests/types' do
    flattened_cases.each do |filename, description, case_obj|
      it "#{filename} — #{description}" do
        if case_obj.expected_failure
          expect { run_test_case(case_obj) }.to raise_error(StandardError)
        else
          run_test_case(case_obj)
        end
      end
    end
  end
end
