# encoding: utf-8

=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

require 'rubygems'
require 'bundler/setup'

require 'ap'
require 'pp'

require_relative 'options'

module Arachni

lib = Options.paths.lib
require lib + 'version'
require lib + 'ruby'
require lib + 'error'
require lib + 'utilities'
require lib + 'support'
require lib + 'uri'
require lib + 'component'
require lib + 'platform'
require lib + 'spider'
require lib + 'parser'
require lib + 'issue'
require lib + 'check'
require lib + 'plugin'
require lib + 'audit_store'
require lib + 'http'
require lib + 'report'
require lib + 'session'
require lib + 'trainer'
require lib + 'browser_cluster'

require Options.paths.mixins + 'progress_bar'

#
# The Framework class ties together all the components.
#
# It's the brains of the operation, it bosses the rest of the classes around.
# It runs the audit, loads checks and reports and runs them according to
# user options.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework
    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include UI::Output

    include Utilities
    include Mixins::Observable

    #
    # {Framework} error namespace.
    #
    # All {Framework} errors inherit from and live under it.
    #
    # When I say Framework I mean the {Framework} class, not the
    # entire Arachni Framework.
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
    #
    class Error < Arachni::Error
    end

    # How many times to request a page upon failure.
    AUDIT_PAGE_MAX_TRIES = 5

    # @return [Options] Instance options
    attr_reader :opts

    # @return   [Arachni::Report::Manager]
    attr_reader :reports

    # @return   [Arachni::Check::Manager]
    attr_reader :checks

    # @return   [Arachni::Plugin::Manager]
    attr_reader :plugins

    # @return   [Session]   Web application session manager.
    attr_reader :session

    # @return   [Spider]   Web application spider.
    attr_reader :spider

    # @return   [Arachni::HTTP]
    attr_reader :http

    # @return   [Hash<String, Integer>]
    #   List of crawled URLs with their HTTP codes.
    attr_reader :sitemap

    # @return   [Trainer]
    attr_reader :trainer

    # @return   [Integer]   Total number of pages added to their audit queue.
    attr_reader :page_queue_total_size

    # @return   [Integer]   Total number of urls added to their audit queue.
    attr_reader :url_queue_total_size

    # @return [Array<String>]
    #   Page URLs which elicited no response from the server and were not audited.
    #   Not determined by HTTP status codes, we're talking network failures here.
    attr_reader :failures

    #
    # @param    [Options]    opts
    # @param    [Block]      block
    #   Block to be passed a {Framework} instance which will then be {#reset}.
    #
    def initialize( opts = Arachni::Options.instance, &block )

        Encoding.default_external = 'BINARY'
        Encoding.default_internal = 'BINARY'

        @opts = opts

        @checks  = Check::Manager.new( self )
        @reports = Report::Manager.new( @opts )
        @plugins = Plugin::Manager.new( self )

        @session = Session.new( @opts )
        reset_spider
        @http    = HTTP::Client.instance

        reset_trainer

        # will store full-fledged pages generated by the Trainer since these
        # may not be be accessible simply by their URL
        @page_queue = Support::Database::Queue.new
        @page_queue_total_size = 0

        # will hold paths found by the spider in order to be converted to pages
        # and ultimately audited by the checks
        @url_queue = Queue.new
        @url_queue_total_size = 0

        # deep clone the redundancy rules to preserve their counter
        # for the reports
        @orig_redundant = @opts.scope.redundant_path_patterns.deep_clone

        @running = false
        @status  = :ready
        @paused  = []

        @audited_page_count = 0
        @sitemap = {}

        @current_url = ''

        # Holds page URLs which returned no response.
        @failures = []
        @retries  = {}

        # Dup filters for the synonymous methods.
        @push_to_url_queue_filter  = Support::LookUp::HashSet.new
        @push_to_page_queue_filter = Support::LookUp::HashSet.new

        if block_given?
            begin
                block.call self
            ensure
                clean_up
                reset
            end
        end
    end

    #
    # Starts the scan.
    #
    # @param   [Block]  block
    #   A block to call after the audit has finished but before running the reports.
    #
    def run( &block )
        prepare

        # catch exceptions so that if something breaks down or the user opted to
        # exit the reports will still run with whatever results Arachni managed to gather
        exception_jail( false ){ audit }

        clean_up
        exception_jail( false ){ block.call } if block_given?
        @status = :done

        # run reports
        @reports.run( audit_store ) if !@reports.empty?

        true
    end

    # Runs loaded checks against a given `page`
    #
    # It will audit just the given page and not use the {Trainer} -- i.e. ignore
    # any new elements that might appear as a result.
    #
    # It will also pass the `page` to the {BrowserCluster} for analysis if the
    # {OptionGroups::Scope#dom_depth_limit_reached? DOM depth limit} has not been
    # reached.
    #
    # @param    [Page]    page
    def audit_page( page )
        return if !page

        if skip_page? page
            print_info "Ignoring page due to exclusion criteria: #{page.dom.url}"
            return false
        end

        @audited_page_count += 1
        add_to_sitemap( page )
        @sitemap.merge!( browser_sitemap )

        print_line
        print_status "Auditing: [HTTP: #{page.code}] #{page.dom.url}"

        if page.platforms.any?
            print_info "Identified as: #{page.platforms.to_a.join( ', ' )}"
        end

        if host_has_has_browser?
            dom_depth = "#{page.dom.depth} (Limit: #{@opts.scope.dom_depth_limit})"
        else
            dom_depth = 'N/A (Could not find browser).'
        end

        print_info "DOM depth: #{dom_depth}"

        call_on_audit_page( page )

        @current_url = page.dom.url.to_s

        http.update_cookies( page.cookiejar )
        perform_browser_analysis( page )

        @checks.schedule.each do |check|
            wait_if_paused
            check_page( check, page )
        end

        harvest_http_responses

        if Check::Auditor.has_timeout_candidates?
            print_line
            print_status "Verifying timeout-analysis candidates for: #{page.dom.url}"
            print_info '---------------------------------------'
            Check::Auditor.timeout_audit_run
        end

        true
    end

    def host_has_has_browser?
        Browser.has_executable?
    end

    def on_audit_page( &block )
        add_on_audit_page( &block )
    end
    alias :on_run_mods :on_audit_page

    # @return   [Bool]
    #   `true` if the {OptionGroups::Scope#page_limit} has been reached, `false`
    #   otherwise.
    def page_limit_reached?
        @opts.scope.page_limit_reached?( @sitemap.size )
    end

    def close_browser
        return if !@browser
        @browser.shutdown
    end

    #
    # Returns the following framework stats:
    #
    # *  `:requests`         -- HTTP request count
    # *  `:responses`        -- HTTP response count
    # *  `:time_out_count`   -- Amount of timed-out requests
    # *  `:time`             -- Amount of running time
    # *  `:avg`              -- Average requests per second
    # *  `:sitemap_size`     -- Number of discovered pages
    # *  `:auditmap_size`    -- Number of audited pages
    # *  `:progress`         -- Progress percentage
    # *  `:curr_res_time`    -- Average response time for the current burst of requests
    # *  `:curr_res_cnt`     -- Amount of responses for the current burst
    # *  `:curr_avg`         -- Average requests per second for the current burst
    # *  `:average_res_time` -- Average response time
    # *  `:max_concurrency`  -- Current maximum concurrency of HTTP requests
    # *  `:current_page`     -- URL of the currently audited page
    # *  `:eta`              -- Estimated time of arrival i.e. estimated remaining time
    #
    # @param    [Bool]  refresh_time    updates the running time of the audit
    #                                       (usefully when you want stats while paused without messing with the clocks)
    #
    # @param    [Bool]  override_refresh
    #
    # @return   [Hash]
    #
    def stats( refresh_time = false, override_refresh = false )
        @start_datetime = Time.now if !@start_datetime

        sitemap_sz  = @sitemap.size
        auditmap_sz = @audited_page_count

        # Progress of audit is calculated as:
        #     amount of audited pages / amount of all discovered pages
        progress = (Float( auditmap_sz ) / sitemap_sz) * 100

        progress = Float( sprintf( '%.2f', progress ) ) rescue 0.0

        # Sometimes progress may slightly exceed 100% which can cause a few
        # strange stuff to happen.
        progress = 100.0 if progress > 100.0

        # Make sure to keep weirdness at bay.
        progress = 0.0 if progress < 0.0

        pb = Mixins::ProgressBar.eta( progress, @start_datetime )

        {
            requests:         http.request_count,
            responses:        http.response_count,
            time_out_count:   http.time_out_count,
            time:             audit_store.delta_time,
            avg:              http.total_responses_per_second,
            sitemap_size:     auditstore_sitemap.size,
            auditmap_size:    auditmap_sz,
            progress:         progress,
            curr_res_time:    http.burst_response_time_sum,
            curr_res_cnt:     http.burst_response_count,
            curr_avg:         http.burst_responses_per_second,
            average_res_time: http.burst_average_response_time,
            max_concurrency:  http.max_concurrency,
            current_page:     @current_url,
            eta:              pb
        }
    end

    #
    # Pushes a page to the page audit queue and updates {#page_queue_total_size}
    #
    # @param    [Page]  page
    #
    # @return   [Bool]
    #   `true` if push was successful, `false` if the `page` matched any
    #   exclusion criteria.
    #
    def push_to_page_queue( page )
        return false if skip_page?( page ) || @push_to_page_queue_filter.include?( page )

        @page_queue << page
        @page_queue_total_size += 1

        add_to_sitemap( page )

        @push_to_page_queue_filter << page

        true
    end

    #
    # Pushes a URL to the URL audit queue and updates {#url_queue_total_size}
    #
    # @param    [String]  url
    #
    # @return   [Bool]
    #   `true` if push was successful, `false` if the `url` matched any
    #   exclusion criteria.
    #
    def push_to_url_queue( url )
        return if page_limit_reached?

        url = to_absolute( url ) || url
        return false if @push_to_url_queue_filter.include?( url ) || skip_path?( url )

        @push_to_url_queue_filter ||= Support::LookUp::HashSet.new

        @url_queue.push( url )
        @url_queue_total_size += 1

        @push_to_url_queue_filter << url

        true
    end

    #
    # @return    [AuditStore]   Scan results.
    #
    # @see AuditStore
    #
    def audit_store
        opts = @opts.to_hash.deep_clone

        # restore the original redundancy rules and their counters
        opts[:scope][:redundant_path_patterns] = @orig_redundant

        AuditStore.new(
            options: opts,
            sitemap: (auditstore_sitemap || {}),
            issues:  @checks.results,
            plugins: @plugins.results,
            start_datetime:  @start_datetime,
            finish_datetime: @finish_datetime
        )
    end
    alias :auditstore :audit_store

    #
    # Runs a report component and returns the contents of the generated report.
    #
    # Only accepts reports which support an `outfile` option.
    #
    # @param    [String]    name
    #   Name of the report component to run, as presented by {#list_reports}'s
    #   `:shortname` key.
    # @param    [AuditStore]    external_report
    #   Report to use -- defaults to the local one.
    #
    # @return   [String]    Scan report.
    #
    # @raise    [Component::Error::NotFound]
    #   If the given report name doesn't correspond to a valid report component.
    #
    # @raise    [Component::Options::Error::Invalid]
    #   If the requested report doesn't format the scan results as a String.
    #
    def report_as( name, external_report = auditstore )
        if !@reports.available.include?( name.to_s )
            fail Component::Error::NotFound, "Report '#{name}' could not be found."
        end

        loaded = @reports.loaded
        begin
            @reports.clear

            if !@reports[name].has_outfile?
                fail Component::Options::Error::Invalid,
                     "Report '#{name}' cannot format the audit results as a String."
            end

            outfile = "/#{Dir.tmpdir}/arachn_report_as.#{name}"
            @reports.run_one( name, external_report, 'outfile' => outfile )

            IO.read( outfile )
        ensure
            File.delete( outfile ) if outfile
            @reports.clear
            @reports.load loaded
        end
    end

    # @return    [Array<Hash>]  Information about all available checks.
    def list_checks( patterns = nil )
        loaded = @checks.loaded

        begin
            @checks.clear
            @checks.available.map do |name|
                path = @checks.name_to_path( name )
                next if !list_check?( path, patterns )

                @checks[name].info.merge(
                    shortname: name,
                    author:    [@checks[name].info[:author]].
                                   flatten.map { |a| a.strip },
                    path:      path.strip
                )
            end.compact
        ensure
            @checks.clear
            @checks.load loaded
        end
    end

    # @return    [Array<Hash>]  Information about all available reports.
    def list_reports( patterns = nil )
        loaded = @reports.loaded

        begin
            @reports.clear
            @reports.available.map do |report|
                path = @reports.name_to_path( report )
                next if !list_report?( path, patterns )

                @reports[report].info.merge(
                    shortname: report,
                    path:      path,
                    author:    [@reports[report].info[:author]].
                                   flatten.map { |a| a.strip }
                )
            end.compact
        ensure
            @reports.clear
            @reports.load loaded
        end
    end

    # @return    [Array<Hash>]  Information about all available plugins.
    def list_plugins( patterns = nil )
        loaded = @plugins.loaded

        begin
            @plugins.clear
            @plugins.available.map do |plugin|
                path = @plugins.name_to_path( plugin )
                next if !list_plugin?( path, patterns )

                @plugins[plugin].info.merge(
                    shortname: plugin,
                    path:      path,
                    author:    [@plugins[plugin].info[:author]].
                                   flatten.map { |a| a.strip }
                )
            end.compact
        ensure
            @plugins.clear
            @plugins.load loaded
        end
    end

    # @return    [Array<Hash>]  Information about all available platforms.
    def list_platforms
        platforms = Platform::Manager.new
        platforms.valid.inject({}) do |h, platform|
            type = Platform::Manager::TYPES[platforms.find_type( platform )]
            h[type] ||= {}
            h[type][platform] = platforms.fullname( platform )
            h
        end
    end

    # @return   [String]
    #   Status of the instance, possible values are (in order):
    #
    #   * `ready` -- Initialised and waiting for instructions.
    #   * `preparing` -- Getting ready to start (i.e. initing plugins etc.).
    #   * `crawling` -- The instance is crawling the target webapp.
    #   * `auditing` -- The instance is currently auditing the webapp.
    #   * `paused` -- The instance has been paused (if applicable).
    #   * `cleanup` -- The scan has completed and the instance is cleaning up
    #           after itself (i.e. waiting for plugins to finish etc.).
    #   * `done` -- The scan has completed, you can grab the report and shutdown.
    #
    def status
        return 'paused' if paused?
        @status.to_s
    end

    # @return   [Bool]  `true` if the framework is running, `false` otherwise.
    def running?
        @running
    end

    # @return   [Bool]  `true` if the framework is paused or in the process of.
    def paused?
        !@paused.empty?
    end

    # @return   [TrueClass]
    #   Pauses the framework on a best effort basis, might take a while to take effect.
    def pause
        spider.pause
        @paused << caller
        true
    end

    # @return   [TrueClass]  Resumes the scan/audit.
    def resume
        @paused.delete( caller )
        spider.resume
        true
    end

    # @return    [String]   Returns the version of the framework.
    def version
        Arachni::VERSION
    end

    #
    # Cleans up the framework; should be called after running the audit or
    # after canceling a running scan.
    #
    # It stops the clock and waits for the plugins to finish up.
    #
    def clean_up
        @status = :cleanup

        @sitemap.merge!( browser_sitemap )

        close_browser
        @page_queue.clear

        @finish_datetime  = Time.now
        @start_datetime ||= Time.now

        # make sure this is disabled or it'll break report output
        disable_only_positives

        @running = false

        # wait for the plugins to finish
        @plugins.block

        true
    end

    def wait_for_browser?
        @browser && !@browser.done?
    end

    def browser_sitemap
        return {} if !@browser
        @browser.sitemap
    end

    def reset_spider
        @spider = Spider.new( @opts )
    end

    def reset_trainer
        @trainer = Trainer.new( self )
    end

    def reset_filters
        @push_to_page_queue_filter.clear
        @push_to_url_queue_filter.clear
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    # Prefer this if you already have an instance.
    #
    def reset
        @page_queue_total_size = 0
        @url_queue_total_size  = 0
        reset_filters
        @failures.clear
        @retries.clear
        @sitemap.clear
        @page_queue.clear

        # this needs to be first so that the HTTP lib will be reset before
        # the rest
        self.class.reset

        clear_observers
        reset_trainer
        reset_spider
        @checks.clear
        @reports.clear
        @plugins.clear
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    def self.reset
        UI::Output.reset_output_options
        Platform::Manager.reset
        Check::Auditor.reset
        ElementFilter.reset
        Element::Capabilities::Auditable.reset
        Check::Manager.reset
        Plugin::Manager.reset
        Report::Manager.reset
        HTTP::Client.reset
    end

    private

    def handle_browser_page( page )
        return if !push_to_page_queue page

        pushed_paths = 0
        page.paths.each do |path|
            pushed_paths +=1 if push_to_url_queue( path )
        end

        print_info 'Got page via DOM/AJAX analysis with the following transitions:'
        print_info page.dom.url

        page.dom.transitions.each do |t|
            element, event = t.first.to_a
            print_info "-- '#{event}' on: #{element}"
        end

        print_info "-- Analysis resulted in #{pushed_paths} usable paths."

    end

    # Passes the `page` to {BrowserCluster#queue} and then pushes
    # the resulting pages to {#push_to_page_queue}.
    #
    # @param    [Page]  page
    #   Page to analyze.
    def perform_browser_analysis( page )
        return if Options.scope.dom_depth_limit.to_i < page.dom.depth + 1 ||
            !host_has_has_browser? || !page.has_script?

        @browser ||= BrowserCluster.new

        # Let's recycle the same request over and over since all of them will
        # have the same callback.
        @browser_request ||= BrowserCluster::Jobs::ResourceExploration.new
        request = @browser_request.forward( resource: page )

        @browser.queue( request ) do |response|
            handle_browser_page response.page
        end

        true
    end

    #
    # Prepares the framework for the audit.
    #
    # Sets the status to 'running', starts the clock and runs the plugins.
    #
    # Must be called just before calling {#audit}.
    #
    def prepare
        @status = :preparing
        @running = true
        @start_datetime = Time.now

        # run all plugins
        @plugins.run
    end

    #
    # Performs the audit
    #
    # Runs the spider, pushes each page or url to their respective audit queue,
    # calls {#audit_queues}, runs the timeout attacks ({Arachni::Check::Auditor.timeout_audit_run}) and finally re-runs
    # {#audit_queues} in case the timing attacks uncovered a new page.
    #
    def audit
        wait_if_paused

        @status = :crawling

        # If we're restricted to a given list of paths there's no reason to run
        # the spider.
        if @opts.scope.restrict_paths && !@opts.scope.restrict_paths.empty?
            @opts.scope.restrict_paths = @opts.scope.restrict_paths.map { |p| to_absolute( p ) }
            @opts.scope.restrict_paths.each { |url| push_to_url_queue( url ) }
        else
            # Initiates the crawl.
            spider.run do |page|
                add_to_sitemap( page )
                push_to_url_queue page.url

                next if page.platforms.empty?
                print_info "Identified as: #{page.platforms.to_a.join( ', ' )}"
            end
        end

        return if checks.empty?

        # Keep auditing until there are no more resources in the queues and the
        # browsers have stopped spinning.
        loop do
            sleep 0.1 while wait_for_browser? && !has_audit_workload?
            audit_queues
            break if !wait_for_browser? && !has_audit_workload?
        end
    end

    def has_audit_workload?
        !@url_queue.empty? || !@page_queue.empty?
    end

    #
    # Audits the URL and Page queues
    #
    def audit_queues
        return if @audit_queues_done == false || checks.empty? || !has_audit_workload?

        @status            = :auditing
        @audit_queues_done = false

        # If for some reason we've got pages in the page queue this early,
        # consume them and get it over with.
        audit_page_queue

        # Go through the URLs discovered by the spider, repeat the request
        # and parse the responses into page objects
        #
        # Yes...repeating the request is wasteful but we can't store the
        # responses of the spider to consume them here because there's no way
        # of knowing how big the site will be.
        while !@url_queue.empty?
            page = Page.from_url( @url_queue.pop, precision: 2 )

            @retries[page.url.hash] ||= 0

            if page.code == 0
                if @retries[page.url.hash] >= AUDIT_PAGE_MAX_TRIES
                    @failures << page.url

                    print_error "Giving up trying to audit: #{page.url}"
                    print_error "Couldn't get a response after #{AUDIT_PAGE_MAX_TRIES} tries."
                else
                    print_bad "Retrying for: #{page.url}"
                    @retries[page.url.hash] += 1
                    @url_queue << page.url
                end

                next
            end

            audit_page Page.from_url( page.url, precision: 2 )

            # Consume pages somehow triggered by the audit and pushed by the
            # trainer or plugins or whatever now to avoid keeping them in RAM.
            audit_page_queue
        end

        audit_page_queue

        @audit_queues_done = true
        true
    end

    #
    # Audits the page queue
    #
    def audit_page_queue
        # this will run until no new elements appear for the given page
        audit_page( @page_queue.pop ) while !@page_queue.empty?
    end

    # Special sitemap for the {#auditstore}.
    #
    # Used only under special circumstances, will usually return the {#sitemap}
    # but can be overridden by the {::Arachni::RPC::Framework}.
    #
    # @return   [Array]
    def auditstore_sitemap
        @sitemap
    end

    def caller
        if /^(.+?):(\d+)(?::in `(.*)')?/ =~ ::Kernel.caller[1]
            Regexp.last_match[1]
        end
    end

    def wait_if_paused
        ::IO::select( nil, nil, nil, 1 ) while paused?
    end

    def harvest_http_responses
        print_status 'Harvesting HTTP responses...'
        print_info 'Depending on server responsiveness and network' <<
            ' conditions this may take a while.'

        # Run all the queued HTTP requests and harvest the responses.
        http.run

        # Needed for some HTTP callbacks.
        http.run

        session.ensure_logged_in
    end

    # Passes a page to the check and runs it.
    # It also handles any exceptions thrown by the check at runtime.
    #
    # @see Page
    #
    # @param    [Arachni::Check::Base]   check  The check to run.
    # @param    [Page]    page
    def check_page( check, page )
        begin
            @checks.run_one( check, page )
        rescue SystemExit
            raise
        rescue => e
            print_error "Error in #{check.to_s}: #{e.to_s}"
            print_error_backtrace e
        end
    end

    def add_to_sitemap( page )
        @sitemap[page.dom.url] = page.code
    end

    def list_report?( path, patterns = nil )
        regexp_array_match( patterns, path )
    end

    def list_check?( path, patterns = nil )
        regexp_array_match( patterns, path )
    end

    def list_plugin?( path, patterns = nil )
        regexp_array_match( patterns, path )
    end

    def regexp_array_match( regexps, str )
        regexps = [regexps].flatten.compact.
            map { |s| s.is_a?( Regexp ) ? s : Regexp.new( s.to_s ) }
        return true if regexps.empty?

        cnt = 0
        regexps.each { |filter| cnt += 1 if str =~ filter }
        cnt == regexps.size
    end

end
end
