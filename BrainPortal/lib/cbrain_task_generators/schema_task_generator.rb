
#
# CBRAIN Project
#
# Copyright (C) 2008-2012
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'fileutils'

# This module handles generation of CbrainTasks from schema and descriptor
# files. The generated code can be added right away to CBRAIN's available tasks
# or written to file for later modification.
#
# NOTE: Only JSON and a single schema (boutiques) is currently supported
module SchemaTaskGenerator

  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  # Directory where descriptor schemas are located
  SCHEMA_DIR = "#{Rails.root.to_s}/lib/cbrain_task_generators/schemas"

  # Default schema file to use when validating auto-loaded descriptors
  DEFAULT_SCHEMA_FILE = 'boutiques.schema.json'

  # Represents a schema to validate task descriptors against
  class Schema

    # Creates a new Schema from either a file path, a string or a hash
    # representing the schema.
    def initialize(schema)
      @schema = SchemaTaskGenerator.expand_json(schema)
    end

    # Validates +descriptor+ against the schema. Returns a list of validation
    # errors or nil if +descriptor+ is valid.
    def validate(descriptor)
      JSON::Validator.fully_validate(
        @schema,
        SchemaTaskGenerator.expand_json(descriptor),
        :errors_as_objects => true
      )
    end

    # Same as +validate+, but throws exceptions on validation errors instead.
    # Still returns nil if +descriptor+ is valid.
    def validate!(descriptor)
      JSON::Validator.validate!(
        @schema,
        SchemaTaskGenerator.expand_json(descriptor),
        :errors_as_objects => true
      )
    end

    # A Schema essentially behaves like a hash, as to allow accessing schema
    # properties. Forwards all other unknown method calls to Hash, if they
    # exist.
    def method_missing(method, *args) #:nodoc:
      if @schema.respond_to?(method)
        @schema.send(method, *args)
      else
        super
      end
    end

  end

  # Encapsulates a CbrainTask generated by this generator
  class GeneratedTask

    # Name of the generated class. Usually a camel-case form
    # of descriptor[:name].
    attr_accessor :name
    # Descriptor used to generate this task, in hash form.
    attr_accessor :descriptor
    # Schema instance used to generate this task.
    attr_accessor :schema
    # Validation errors produced when validating the task's descriptor, if any.
    attr_accessor :validation_errors
    # Generated Ruby/HTML source for this task. Hash with at least the keys:
    # [:portal]      BrainPortal side task class Ruby source. Contains a class
    #                inheriting/implementing PortalTask.
    # [:bourreau]    Bourreau side task class Ruby source. Contains a class
    #                inheriting/implementing ClusterTask.
    # [:task_params] Ruby ERB form template for the task's params (edit) page.
    # [:show_params] Ruby ERB template for the task's show page.
    # [:edit_help]   Ruby ERB template for the task's parameter help popup.
    attr_accessor :source

    # Create a new encapsulated generated CbrainTask from the output of the
    # generator (+SchemaTaskGenerator+::+generate+ method). +attributes+ is
    # expected to be a hash matching this object's attributes (:source, :name,
    # :descriptor, etc.)
    def initialize(attributes)
      attributes.each do |name, value|
        instance_variable_set("@#{name}", value)
      end
    end

    # Integrates the encapsulated CbrainTask in this CBRAIN installation.
    # Unless +register+ is specified to be false, this method will add the
    # required Tool if necessary for the CbrainTask to be
    # useable right away (since almost all information required to make the
    # Tool and ToolConfig objects is available in the spec). The ToolConfig
    # will also be created unless +create_tool_config+ is false.
    # Also, if +multi_version+ is specified, this method will wrap the
    # encapsulated CbrainTask in a version switcher class to allow different
    # CbrainTask classes for each tool version.
    # Returns the newly generated CbrainTask subclass.
    def integrate(register: true, create_tool_config: false, multi_version: false)
      # Make sure the task class about to be generated does not already exist,
      # to avoid mixing the classes up.
      name = SchemaTaskGenerator.classify(@name)
      [ Object, CbrainTask ].select { |m| m.const_defined?(name) }.each do |m|
        Rails.logger.warn(
          "WARNING: #{name} is already defined in #{m.name}; " +
          "undefining to avoid collisions"
        ) unless multi_version

        m.send(:remove_const, name)
      end

      # As the same code is used to dynamically load tasks descriptors and
      # create task templates, the class definitions are generated as strings
      # (Otherwise the source wouldn't be available to write down the generated
      # templates). This forces the use of eval instead of the much nicer,
      # faster and easier to maintain alternatives. :(
      eval @source[Rails.root.to_s =~ /BrainPortal$/ ? :portal : :bourreau]

      # Try and retrieve the just-generated task class
      task   = name.constantize rescue nil
      task ||= "CbrainTask::#{name}".constantize

      # Since the task class doesn't have a matching cbrain_plugins directory
      # tree, some methods need to be added/redefined to ensure the cooperation
      # of views and controllers.
      generated = self

      # The task class has no public_path.
      task.define_singleton_method(:public_path)    { |public_file| nil }

      # Make sure the task class still has access to its generated source
      task.define_singleton_method(:generated_from) { generated }

      # Offer access to the raw string version of the view partials for use
      # in views instead of the cbrain_plugins paths.
      task.define_singleton_method(:raw_partial) do |partial|
        ({
          :task_params => generated.source[:task_params],
          :show_params => generated.source[:show_params],
          :edit_help   => generated.source[:edit_help]
        })[partial]
      end

      # Write out a help file for this Boutiques task
      helpFileName = name + "_help.html" 
      helpFileDir = "cbrain_plugins/cbrain_tasks/help_files/"
      basePath = Rails.root.join('public/' + helpFileDir) 
      FileUtils.mkdir_p basePath.to_s # creates directory if needed
      helpfilePath = basePath.join(helpFileName).to_s
      File.open( helpfilePath , "w" ){ |f|
        f.write( generated.source[:edit_help] )
      }
      FileUtils.chmod 0775, helpfilePath

      # Add a helper method for accessing the help file (for use on the tools page) 
      task.define_singleton_method(:get_boutiques_help_filepath){ helpFileDir + helpFileName }

      # If multi-versioning is enabled, replace the task class object constant
      # in CbrainTask (or Object) by a version switcher wrapper class.
      if multi_version
        # Build the corresponding switcher and add the task's version and class
        # to it.
        version  = @descriptor['tool-version']
        switcher = SchemaTaskGenerator.version_switcher(name)
        switcher.known_versions[version] = task

        # Redefine the CbrainTask or Object constant pointing to the task's
        # class to point to the switcher instead.
        [ Object, CbrainTask ].select { |m| m.const_defined?(name) }.each do |m|
          m.send(:remove_const, name)
          m.const_set(name, switcher)
        end
      end

      # With the task class and descriptor, we have enough information to
      # generate a Tool and ToolConfig to register the tool into CBRAIN.
      register(task,create_tool_config) if register

      task
    end

    # Register a newly generated CbrainTask subclass (+task+) in this CBRAIN
    # installation, creating the appropriate Tool object from the information 
    # contained in the descriptor. A ToolConfig is also created, unless 
    # +create_tool_config+ is false. The newly created Tool and ToolConfig 
    # will initially belong to the core admin.
    def register(task,create_tool_config)
      name         = @descriptor['name']
      version      = @descriptor['tool-version'] || '(unknown)'
      description  = @descriptor['description']  || ''
      docker_image = @descriptor['docker-image']
      resource     = RemoteResource.current_resource 

      # Create and save a new Tool for the task, unless theres already one.
      Tool.new(
        :name              => name,
        :user_id           => User.admin.id,
        :group_id          => User.admin.own_group.id,
        :category          => "scientific tool",
        :cbrain_task_class => task.to_s,
        :description       => description
      ).save! unless
        Tool.exists?(:cbrain_task_class => task.to_s)

      # Create and save a new ToolConfig for the task on this server, unless
      # theres already one. Only applies to Bourreaux (as it would make no
      # sense on the portal).
      return if Rails.root.to_s =~ /BrainPortal$/

      ToolConfig.new(
        :tool_id      => task.tool.id,
        :bourreau_id  => resource.id,
        :group_id     => Group.everyone.id,
        :version_name => version,
        :description  => "#{name} #{version} on #{resource.name}",
        :docker_image => docker_image
      ).save! unless !create_tool_config ||
        ToolConfig.exists?(
          :tool_id      => task.tool.id,
          :bourreau_id  => resource.id,
          :version_name => version
        )
    end

    # Writes the encapsulated CbrainTask as a directory tree under +path+ under
    # the CBRAIN plugin format;
    #   source[:portal]      -> <task name>/portal/<task name>.rb
    #   source[:bourreau]    -> <task name>/bourreau/<task name>.rb
    #   source[:task_params] -> <task name>/views/_task_params.html.erb
    #   source[:show_params] -> <task name>/views/_show_params.html.erb
    #   source[:edit_help]   -> <task name>/views/public/edit_params_help.html
    def to_directory(path)
      name = @name.underscore
      path = Pathname.new(path.to_s) + name

      FileUtils.mkpath(path)
      Dir.chdir(path) do
        ['portal', 'bourreau', 'views/public'].each { |d| FileUtils.mkpath(d) }

        IO.write("portal/#{name}.rb",                  @source[:portal])
        IO.write("bourreau/#{name}.rb",                @source[:bourreau])
        IO.write("views/_task_params.html.erb",        @source[:task_params])
        IO.write("views/_show_params.html.erb",        @source[:show_params])
        IO.write("views/public/edit_params_help.html", @source[:edit_help])
      end
    end

  end

  # Generates a CbrainTask from +descriptor+, which is expected to validate
  # against +schema+. +schema+ is expected to be either a +Schema+ instance,
  # a path to a schema file, the schema in string format or a hash
  # representing the schema.
  # Similarly to +schema+, +descriptor+ is expected to be either a path to a
  # descriptor file, the descriptor in string format or a hash representing
  # the descriptor.
  # By default, the validation of +descriptor+ against +schema+ is strict
  # and +generate+ will abort at any validation error. Set +strict_validation+
  # to false if you wish for the generator to try and generate the task despite
  # validation issues.
  def self.generate(schema, descriptor, strict_validation = true)
    descriptor = self.expand_json(descriptor)
    name       = self.classify(descriptor['name'])
    schema     = Schema.new(schema) unless schema.is_a?(Schema)
    errors     = schema.send(
      strict_validation ? :'validate!' : :validate,
      descriptor
    ) || []

    apply_template = lambda do |template|
      ERB.new(IO.read(
        Rails.root.join('lib/cbrain_task_generators/templates', template).to_s
      ), nil, '%<>>-').result(binding)
    end

    GeneratedTask.new(
      :name              => name,
      :descriptor        => descriptor,
      :schema            => schema,
      :validation_errors => errors,
      :source            => {
        :portal      => apply_template.('portal.rb.erb'),
        :bourreau    => apply_template.('bourreau.rb.erb'),
        :task_params => apply_template.('task_params.html.erb.erb'),
        :show_params => apply_template.('show_params.html.erb.erb'),
        :edit_help   => apply_template.('edit_help.html.erb')
      },
    )
  end

  # Generate (or retrieve if it has been generated already) a version switcher
  # class for CbrainTask subclasses named +name+. The version switcher class
  # will behave just like a blank CbrainTask subclass until it is assigned
  # a ToolConfig. It will then replace its methods with the ones from the
  # CbrainTask subclass corresponding to that particular version:
  #   class A < PortalTask
  #     def f; :a; end
  #   end
  #
  #   class B < PortalTask
  #     def f; :b; end
  #   end
  #
  #   s = version_switcher('A')
  #   s.known_versions['1.1'] = A
  #   s.known_versions['1.2'] = B
  #
  #   s.tool_config = ToolConfig.new(:version => '1.1')
  #   s.f # :a
  def self.version_switcher(name)
    base = Rails.root.to_s =~ /BrainPortal$/ ? PortalTask : ClusterTask
    @@version_switchers       ||= {}
    @@version_switchers[name] ||= Class.new(base) do

      # Versions known to this version switcher and their associated CbrainTask
      # subclasses.
      def self.known_versions
        class_variable_set(:@@known_versions, {}) unless
          class_variable_defined?(:@@known_versions)

        class_variable_get(:@@known_versions)
      end

      # Add a few singleton methods on the object to perform a version switch
      # once the tool config is set.
      after_initialize do
        # FIXME: the simplest and most straightforward way to make the version
        # switcher task instance become an instance of the version-specific
        # class would be to directly change the instance's class.
        # At the time of writing, this is impossible in Ruby.
        # This method (+as_version+) tries its best to mimic the missing
        # functionality.

        # FIXME: unfortunately, while the technique +as_version+ uses is
        # more-or-less sound Ruby-wise (it bulk-imports the version class
        # instance methods into the version switcher instance's singleton
        # class), it apparently overrides/messes up some sensitive core Ruby
        # methods which make Ruby segfault when the object is garbage collected.

        # As such, this version switching functionality is not currently in use,
        # for lack of a working technique to try to 'convert' the version
        # switcher instance.

        # Convert this blank CbrainTask object (instance of the version switcher
        # class) to a more-or-less real instance of the class corresponding to
        # +version+ by including all of its methods in, replacing the defaults
        # from PortalTask or ClusterTask.
        define_singleton_method(:as_version) do |version|
          # Try to get the version-specific class corresponding to +version+,
          # falling back on the first defined version in known_versions if it
          # cannot be found.
          known = self.class.known_versions
          unless (version_class = known[version])
            cb_error "No known versions for #{self.class.name}!?" unless
              known.present?

            logger.warn(
              "WARNING: Unknown version #{version} for #{self.class.name}, " +
              "using #{known.first[0]} instead."
            )

            version, version_class = known.first
          end

          # An object can only be given methods for a single version, and
          # exactly once. Conflicts and odd issues could occur otherwise.
          # Thus, there is no longer a need for :as_version or the tool_config
          # setter hooks.
          [ :as_version, :tool_config=, :tool_config_id= ].each do |m|
            self.singleton_class.send(:remove_method, m) rescue nil
          end

          # Use the Ruby 2.0 refinement API to include version_class methods
          # inside this object's singleton class (or metaclass)
          self.singleton_class.include(Module.new do
            include refine(version_class) { }
          end)

          # And try to make the object appear to be a version_class.
          define_singleton_method(:class) { version_class }
          define_singleton_method(:kind_of?) { |klass| is_a?(klass) }
          define_singleton_method(:is_a?) do |klass|
            klass <= version_class || super(klass)
          end
          define_singleton_method(:instance_of?) do |klass|
            klass == version_class || super(klass)
          end
        end

        # If we dont have a tool config already, try to catch the exact moment
        # when the version switcher instance gets assigned its tool config and
        # invoke as_version when it happens.
        if self.tool_config
          self.as_version(self.tool_config.version_name)
        else
          [ :tool_config=, :tool_config_id= ].each do |method|
            define_singleton_method(method) do |*args|
              value = super(*args)
              self.as_version(self.tool_config.version_name) if self.tool_config
              value
            end
          end
        end
      end

      # Just like generated task classes, the version switcher doesn't have a
      # cbrain_plugins directory structure and needs a few methods for views
      # and controllers, adjusted to reflect that a ToolConfig is needed to
      # access the real task class.

      # No public path
      def self.public_path(public_file)
        nil
      end

      # No generated source (yet)
      def self.generated_from
        nil
      end

      # Stubbed out raw view partials
      def self.raw_partial(partial)
        ({
          :task_params => %q{ No version specified },
          :show_params => %q{ No version specified }
        })[partial]
      end

    end
  end

  # Returns the default Schema instance to use when validating descriptors
  # without a specific schema or when auto-loading descriptors.
  # (constructed from DEFAULT_SCHEMA_FILE)
  def self.default_schema
    @@default_schema ||= Schema.new("#{SCHEMA_DIR}/#{DEFAULT_SCHEMA_FILE}")
  end

  # Utility method to convert a JSON string or file path into a hash.
  # Returns the hash directly if a hash is given.
  def self.expand_json(obj)
    return obj unless obj.is_a?(String)

    JSON.parse!(File.exists?(obj) ? IO.read(obj) : obj)
  end

  # Utility method to convert a string (+str+) to an identifier suitable for a
  # Ruby class name. Similar to Rails' classify, but tries to handle more cases.
  def self.classify(str)
    str.gsub!('-', '_')
    str.gsub!(/\W/, '')
    str.gsub!(/^\d/, '')
    str.camelize
  end

  private

  # Utility/helper methods used in templates.

  # Create a function call formatter for +func+ with possible arguments lists
  # +args+. The generated formatter will accept a list of arguments to format
  # a call with. (formatter.(['a', 'b']) -> 'func(a, b)')
  # If given, +block+ will be used to convert each value in +args+
  # (and the argument passed to the generated function) to an argument list.
  #
  # Example:
  #   a = [{ :a => 1, :b => 2 }, { :a => 2, :b => 4 }]
  #   f = format_call('f', a) { |a| [ a[:a], a[:b] ] }
  #   f.({ :a => 1, :b => 2}) # gives 'f(1, 2)'
  def self.format_call(func, args, &block)
    args = args.map { |a| block.(a) } if block

    widths = (args.first rescue []).zip(*args).map do |array|
      array.map { |v| v.length rescue 0 }.max + 1
    end

    lambda do |args|
      inner = (block ? block.(args) : args)
        .reject(&:blank?)
        .each_with_index
        .map { |v, i| "%-#{widths[i]}s" % (v + ',') }
        .join(' ')
        .gsub(/,\s*$/, '')

      "#{func}(#{inner})"
    end
  end

end
