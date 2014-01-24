=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

require_relative 'job/result'

module Arachni
class BrowserCluster

# Represents a job to be passed to the {BrowserCluster#queue} for deferred
# execution.
#
# @abstract
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
class Job

    class <<self
        # Increments the {#id} upon {#initialize initialization}.
        #
        # @return   [Integer]
        def increment_id
            @@id ||= 0
            @@id += 1
        end
    end

    # @return   [Peer]
    #   Browser to use in order to perform the relevant {#run task} -- set by
    #   {BrowserCluster} via {#configure_and_run}.
    attr_reader :browser

    # @param    [Hash]  options
    def initialize( options = {} )
        @options = options.dup
        @id      = options.delete(:id) || self.class.increment_id
    end

    # @note The following resources will be available at the time of execution:
    #
    #       * {#browser}
    #
    # Encapsulates the job payload.
    #
    # @abstract
    def run
    end

    # Configures the job with the necessary resources, {#run runs} the payload
    # and then removes the assigned resources.
    #
    # @param    [Peer]  browser
    #   Browser to use in order to perform the relevant task -- set by
    #   {BrowserCluster::Peer#run_job}.
    def configure_and_run( browser )
        set_resources( browser )
        run
    ensure
        remove_resources
    end

    # @return   [Job]
    #   {#dup Copy} of `self` with any resources set by {#configure_and_run}
    #   removed.
    def clean_copy
        dup.tap { |j| j.remove_resources }
    end

    # @return   [Job]   Copy of `self`
    def dup
        self.class.new add_id( @options )
    end

    # @param    [Hash]  options See {#initialize}.
    # @return   [Job]
    #   Re-used request (mainly its {#id} and thus its callback as well),
    #   configured with the given `options`.
    def forward( options = {} )
        self.class.new add_id( options )
    end

    # @param    [Job]  job_type Job class under {Jobs}.
    # @param    [Hash]  options Initialization options for `job_type`.
    # @return   [Job]
    #   Forwarded request (preserving its {#id} and thus its callback as well),
    #   configured with the given `options`.
    def forward_as( job_type, options = {} )
        job_type.new add_id( options )
    end

    # @return   [Integer]
    #   ID, used by the {BrowserCluster}, to tie requests to callbacks.
    def id
        @id
    end

    protected

    def remove_resources
        @browser = nil
    end

    private

    def add_id( options )
        options.merge( id: @id )
    end

    def set_resources( browser )
        @browser = browser
    end

end

end
end
