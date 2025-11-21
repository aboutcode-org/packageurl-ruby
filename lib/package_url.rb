# frozen_string_literal: true

require_relative 'package_url/version'

require 'uri'
require 'cgi'

# A package URL, or _purl_, is a URL string used to
# identify and locate a software package in a mostly universal and uniform way
# across programing languages, package managers, packaging conventions, tools,
# APIs and databases.
#
# A purl is a URL composed of seven components:
#
# ```
# scheme:type/namespace/name@version?qualifiers#subpath
# ```
#
# For example,
# the package URL for this Ruby package at version 0.1.0 is
# `pkg:ruby/mattt/packageurl-ruby@0.1.0`.
class PackageURL
  # Raised when attempting to parse an invalid package URL string.
  # @see #parse
  class InvalidPackageURL < ArgumentError; end

  SCHEME = 'pkg'
  VALID_TYPE_CHARS = /\A[A-Za-z0-9.\-_]+\z/

  # The package type or protocol, such as `"gem"`, `"npm"`, and `"github"`.
  attr_reader :type

  # A name prefix, specific to the type of package.
  # For example, an npm scope, a Docker image owner, or a GitHub user.
  attr_reader :namespace

  # The name of the package.
  attr_reader :name

  # The version of the package.
  attr_reader :version

  # Extra qualifying data for a package, specific to the type of package.
  # For example, the operating system or architecture.
  attr_reader :qualifiers

  # An extra subpath within a package, relative to the package root.
  attr_reader :subpath

  # Constructs a package URL from its components
  # @param type [String] The package type or protocol.
  # @param namespace [String] A name prefix, specific to the type of package.
  # @param name [String] The name of the package.
  # @param version [String] The version of the package.
  # @param qualifiers [Hash] Extra qualifying data for a package, specific to the type of package.
  # @param subpath [String] An extra subpath within a package, relative to the package root.
  def initialize(type:, name:, namespace: nil, version: nil, qualifiers: nil, subpath: nil)
    raise ArgumentError, 'type is required' if type.nil? || type.empty?
    raise ArgumentError, 'name is required' if name.nil? || name.empty?

    @type = type.downcase
    @namespace = namespace
    @name = name
    @version = version
    @qualifiers = qualifiers
    @subpath = subpath
  end

  def self.quote(str)
    return '' if str.nil? || str.empty?
    
    str.to_s.split(' ').map { |part|
      part.split('+').map { |segment|
        encoded = CGI.escape(segment)
        encoded.gsub('%3A', ':')
      }.join('%2B')
    }.join('%20')
  end

  def self.unquote(str)
    return '' if str.nil? || str.empty?
    
    str.to_s.gsub('+', '%2B').gsub(' ', '%20').then { |s| CGI.unescape(s) }
  end

  # Get the appropriate quoter function
  def self.get_quoter(encode)
    case encode
    when true
      method(:quote)
    when false
      method(:unquote)
    when nil
      ->(x) { x }
    end
  end

  # Normalize type component
  def self.normalize_type(type, encode = true)
    return nil if type.nil? || type.to_s.strip.empty?
    
    quoter = get_quoter(encode)
    type_str = quoter.call(type.to_s).strip.downcase
    type_str.empty? ? nil : type_str
  end

  # Normalize namespace component
  def self.normalize_namespace(namespace, ptype = nil, encode = true)
    return nil if namespace.nil? || namespace.to_s.strip.empty?
    
    namespace_str = namespace.to_s.strip.gsub(%r{^/+|/+$}, '')
    
    # Types that require lowercase namespace
    lowercase_types = %w[bitbucket github pypi gitlab composer luarocks qpkg alpm apk hex]
    namespace_str = namespace_str.downcase if lowercase_types.include?(ptype)
    
    # CPAN requires uppercase
    namespace_str = namespace_str.upcase if ptype == 'cpan'
    
    segments = namespace_str.split('/').map(&:strip).reject(&:empty?)
    quoter = get_quoter(encode)
    segments_quoted = segments.map { |seg| quoter.call(seg) }
    
    result = segments_quoted.join('/')
    result.empty? ? nil : result
  end

  # Normalize MLflow name (special case)
  def self.normalize_mlflow_name(name_str, qualifiers)
    if qualifiers.is_a?(Hash)
      repo_url = qualifiers['repository_url']
      return name_str if repo_url&.downcase&.include?('azureml')
      return name_str.downcase if repo_url&.downcase&.include?('databricks')
    elsif qualifiers.is_a?(String)
      return name_str if qualifiers.downcase.include?('azureml')
      return name_str.downcase if qualifiers.downcase.include?('databricks')
    end
    
    name_str
  end

  # Normalize name component
  def self.normalize_name(name, qualifiers = nil, ptype = nil, encode = true)
    return nil if name.nil? || name.to_s.strip.empty?
    
    quoter = get_quoter(encode)
    name_str = quoter.call(name.to_s).strip.gsub(%r{^/+|/+$}, '')
    
    # Special handling for MLflow
    return normalize_mlflow_name(name_str, qualifiers) if ptype == 'mlflow'
    
    # Types that require lowercase name
    lowercase_types = %w[bitbucket github pypi gitlab composer luarocks oci npm alpm apk bitnami hex pub]
    name_str = name_str.downcase if lowercase_types.include?(ptype)
    
    # PyPI: replace underscores with hyphens
    name_str = name_str.tr('_', '-').downcase if ptype == 'pypi'
    
    # Hackage: replace underscores with hyphens (but don't force lowercase)
    name_str = name_str.tr('_', '-') if ptype == 'hackage'
    
    # Pub: only lowercase alphanumeric and underscores
    name_str = name_str.downcase.gsub(/[^a-z0-9]/, '_') if ptype == 'pub'
    
    name_str.empty? ? nil : name_str
  end

  # Normalize version component
  def self.normalize_version(version, ptype = nil, encode = true)
    return nil if version.nil? || version.to_s.strip.empty?
    
    quoter = get_quoter(encode)
    version_str = quoter.call(version.to_s.strip)
    
    # Lowercase for specific types
    version_str = version_str.downcase if %w[huggingface oci].include?(ptype)
    
    version_str.empty? ? nil : version_str
  end

  # Normalize qualifiers component
  def self.normalize_qualifiers(qualifiers, encode = true)
    return (encode ? nil : {}) if qualifiers.nil? || (qualifiers.respond_to?(:empty?) && qualifiers.empty?)
    
    qualifiers_pairs = if qualifiers.is_a?(String)
                         qualifiers_list = qualifiers.split('&')
                         if qualifiers_list.any? { |kv| !kv.include?('=') }
                           raise InvalidPackageURL, "Invalid qualifier. Must be a string of key=value pairs: #{qualifiers_list.inspect}"
                         end
                         
                         qualifiers_list.map { |kv| kv.partition('=') }.map { |k, _, v| [k, v] }
                       elsif qualifiers.is_a?(Hash)
                         qualifiers.to_a
                       else
                         raise InvalidPackageURL, "Invalid qualifier. Must be a string or hash: #{qualifiers.inspect}"
                       end
    
    quoter = get_quoter(encode)
    qualifiers_map = {}
    
    qualifiers_pairs.each do |k, v|
      next unless k && !k.strip.empty? && v && !v.strip.empty?
      
      qualifiers_map[k.strip.downcase] = quoter.call(v)
    end
    
    valid_chars = /\A[a-zA-Z0-9.\-_]+\z/
    
    qualifiers_map.each_key do |key|
      raise InvalidPackageURL, 'A qualifier key cannot be empty' if key.empty?
      raise InvalidPackageURL, "A qualifier key cannot be percent encoded: #{key.inspect}" if key.include?('%')
      raise InvalidPackageURL, "A qualifier key cannot contain spaces: #{key.inspect}" if key.include?(' ')
      raise InvalidPackageURL, "A qualifier key must be composed only of ASCII letters and numbers, period, dash and underscore: #{key.inspect}" unless key.match?(valid_chars)
      raise InvalidPackageURL, "A qualifier key cannot start with a number: #{key.inspect}" if key[0].match?(/\d/)
    end
    
    qualifiers_map = qualifiers_map.sort.to_h
    
    return qualifiers_map unless encode
    
    qualifier_string = qualifiers_map.map { |k, v| "#{k}=#{v}" }.join('&')
    qualifier_string.empty? ? nil : qualifier_string
  end

  # Normalize subpath component
  def self.normalize_subpath(subpath, encode = true)
    return nil if subpath.nil? || subpath.to_s.strip.empty?
    
    quoter = get_quoter(encode)
    segments = subpath.to_s.split('/').reject { |s| s.strip.empty? || s == '.' || s == '..' }
    segments_quoted = segments.map { |s| quoter.call(s) }
    
    subpath_str = segments_quoted.join('/')
    subpath_str.empty? ? nil : subpath_str
  end

  # Creates a new PackageURL from a string.
  # @param [String] string The package URL string.
  # @raise [InvalidPackageURL] If the string is not a valid package URL.
  # @return [PackageURL]
  def self.parse(string)
    raise InvalidPackageURL, 'A purl string argument is required.' if string.nil? || string.strip.empty?

    scheme, sep, remainder = string.partition(':')
    unless sep == ':' && scheme == SCHEME
      raise InvalidPackageURL, "purl is missing the required 'pkg:' scheme component: #{string.inspect}"
    end

    # Strip leading slashes (handles ://, ///)
    remainder = remainder.strip.sub(%r{^/+}, '')

    type, sep, remainder = remainder.partition('/')
    if type.nil? || type.empty? || sep.empty?
      raise InvalidPackageURL, "purl is missing the required type component: #{string.inspect}"
    end

    unless type.match?(VALID_TYPE_CHARS)
      raise InvalidPackageURL, "purl type must be composed only of ASCII letters and numbers, period, dash and underscore: #{type.inspect}"
    end

    if type[0] =~ /\d/
      raise InvalidPackageURL, "purl type cannot start with a number: #{type.inspect}"
    end

    type = type.downcase

    original_remainder = remainder.dup

    # Parse URI components using URI class
    begin
      uri = URI.parse("http://dummy/#{remainder}")
      path = uri.path.sub(%r{^/}, '')
      qualifiers_str = uri.query
      subpath = uri.fragment
    rescue URI::InvalidURIError
      raise InvalidPackageURL, "Invalid PURL remainder: #{remainder.inspect}"
    end

    # Handle special cases where colons appear in path (scheme/authority handling)
    # This is to handle cases like pkg:golang/golang.org/x/text
    if uri.host && uri.host != 'dummy'
      path = "#{uri.host}:#{path}"
    end

    namespace = ''
    version = nil

    # Special handling for NPM packages with @ namespace
    if type == 'npm' && path.start_with?('@')
      parts = path.split('/', 2)
      namespace = parts[0]
      path = parts[1] || ''
    end

    # Extract version if present (after @)
    if path.include?('@')
      # Use rpartition to get the last @ occurrence
      parts = path.rpartition('@')
      if parts[1] == '@' # Found the separator
        path = parts[0]
        version = parts[2]
      end
    end

    # Parse namespace and name
    ns_name = path.strip.gsub(%r{^/+|/+$}, '')
    ns_name_parts = ns_name.split('/').map(&:strip).reject(&:empty?)

    name = ''
    if namespace.empty? && ns_name_parts.length > 1
      name = ns_name_parts[-1]
      namespace = ns_name_parts[0...-1].join('/')
    elsif ns_name_parts.length == 1
      name = ns_name_parts[0]
    elsif ns_name_parts.empty?
      raise InvalidPackageURL, "purl is missing the required name component: #{string.inspect}"
    end

    raise InvalidPackageURL, "purl is missing the required name component: #{string.inspect}" if name.empty?

    # Normalize all components (encode=false means decode/parse mode)
    type, namespace, name, version, qualifiers_hash, subpath = normalize_all(
      type, namespace, name, version, qualifiers_str, subpath, false
    )

    new(
      type: type,
      namespace: namespace,
      name: name,
      version: version,
      qualifiers: qualifiers_hash,
      subpath: subpath
    )
  end

  # Normalize all components at once
  def self.normalize_all(type, namespace, name, version, qualifiers, subpath, encode)
    type_norm = normalize_type(type, encode)
    namespace_norm = normalize_namespace(namespace, type_norm, encode)
    name_norm = normalize_name(name, qualifiers, type_norm, encode)
    version_norm = normalize_version(version, type, encode)
    qualifiers_norm = normalize_qualifiers(qualifiers, encode)
    subpath_norm = normalize_subpath(subpath, encode)

    [type_norm, namespace_norm, name_norm, version_norm, qualifiers_norm, subpath_norm]
  end

  # Returns a hash containing the
  # scheme, type, namespace, name, version, qualifiers, and subpath components
  # of the package URL.
  def to_h
    {
      scheme: scheme,
      type: @type,
      namespace: @namespace,
      name: @name,
      version: @version,
      qualifiers: @qualifiers,
      subpath: @subpath
    }
  end

  # Returns a string representation of the package URL.
  # Package URL representations are created according to the instructions from
  # https://github.com/package-url/purl-spec/blob/0b1559f76b79829e789c4f20e6d832c7314762c5/PURL-SPECIFICATION.rst#how-to-build-purl-string-from-its-components.
  def to_s
    # Normalize and encode all components
    type_n, namespace_n, name_n, version_n, qualifiers_n, subpath_n = self.class.normalize_all(
      @type, @namespace, @name, @version, @qualifiers, @subpath, true
    )

    purl = +"#{SCHEME}:#{type_n}/"

    purl << "#{namespace_n}/" if namespace_n && !namespace_n.empty?
    purl << name_n.to_s
    purl << "@#{version_n}" if version_n

    if qualifiers_n && !qualifiers_n.empty?
      # qualifiers_n is already encoded as a string when encode=true
      purl << "?#{qualifiers_n}"
    end

    purl << "##{subpath_n}" if subpath_n && !subpath_n.empty?

    purl
  end

  # Returns an array containing the
  # scheme, type, namespace, name, version, qualifiers, and subpath components
  # of the package URL.
  def deconstruct
    [scheme, @type, @namespace, @name, @version, @qualifiers, @subpath]
  end

  # Returns a hash containing the
  # scheme, type, namespace, name, version, qualifiers, and subpath components
  # of the package URL.
  def deconstruct_keys(_keys)
    to_h
  end
end