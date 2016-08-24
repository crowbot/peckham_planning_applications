# This is a template for a Ruby scraper on morph.io (https://morph.io)
# including some code snippets below that you should find helpful

require 'scraperwiki'
require 'mechanize'
require 'date'
require 'uri'

class Scraper

  HOST = 'http://planbuild.southwark.gov.uk:8190'
  VERBOSE = true
  READ_CACHE = false
  WRITE_CACHE = false
  PLANNING_DIR = '/online-applications'
  SUMMARY_PATH = "#{PLANNING_DIR}/applicationDetails.do?activeTab=summary&keyVal="
  DETAILS_PATH = "#{PLANNING_DIR}/applicationDetails.do?activeTab=details&keyVal="
  DATES_PATH = "#{PLANNING_DIR}/applicationDetails.do?activeTab=dates&keyVal="
  MAKE_COMMENT_PATH = "#{PLANNING_DIR}/applicationDetails.do?activeTab=makeComment&keyVal="
  REQUEST_RETRIES = 2
  CONTENT_RETRIES = 2

  attr_accessor :agent

  def hash_to_querystring(data)
    "?" + data.collect { |attr, value|
      if value.respond_to?(:read)
        value = value.read
      end
      CGI.escape(attr.to_s) << '=' << CGI.escape(value.to_s)
    }.join('&')
  end

  def get_page(path, data, method=:get)
    puts "path is #{path}" if VERBOSE
    cache_found = false
    cache_path = "#{Dir.pwd}/cache/#{URI.parse(HOST).host}#{path}"
    cache_path = cache_path.gsub(/;jsessionid=[^?]*/, '')
    cache_path = cache_path.gsub("?", "_")
    if data and method == :post
      cache_path += hash_to_querystring(data)
    end
    cache_path = "#{cache_path}.html" unless cache_path.end_with?('.html')
    puts "Cache path is #{cache_path}" if VERBOSE
    if READ_CACHE
      cache_found = File.exist?(cache_path)
    end
    if cache_found
      puts "Using cached file #{cache_path}" if VERBOSE
      page = agent.get("file:///#{cache_path}")
    else
      url = "#{HOST}#{path}"
      puts "Using remote file #{url}" if VERBOSE

      begin
        retries ||= 0
        if method == :get
          page = agent.get(url)
        else
          page = agent.post(url, data)
        end
      rescue
        puts "Request failed #{url} (#{method})" if VERBOSE
        sleep(3) && retry if (retries += 1) < REQUEST_RETRIES
      end

      if WRITE_CACHE
        File.open(cache_path, 'w'){ |file| file.write(page.body) }
      end
    end
    return page
  end

  def submit_search_form(date, search_type, ward=nil)
    # Read in a page
    search_path = '/online-applications/search.do?action='
    if search_type == :weekly
      search_path += 'weeklyList'
    else
      search_path += 'monthlyList'
    end

    page = get_page(search_path, {}, :get)
    form = page.form('searchCriteriaForm')
    form.action = "#{HOST}#{form.action}"
    form['searchType'] = 'Application'

    if ward
      form['searchCriteria.ward'] = ward
    end
    if search_type == :weekly
      previous_monday = date - date.wday + 1
      if previous_monday == date
        previous_monday = previous_monday - 7
      end
      if previous_monday == date + 1
        previous_monday = date - 6
      end

      form['week'] = previous_monday.strftime('%d %b %Y')
      puts "Date is #{weekly_list_form['week']}" if VERBOSE
    else
      form['month'] = date.strftime('%b %Y')
    end

    form['dateType'] = 'DC_Validated'

    if VERBOSE
      puts "Submitting #{search_type} search form"
    end
    agent.submit(form, form.buttons.first)
  end

  def parse_results_page(page)
    begin
      retries ||= 0
      results_info = page.at('span.showing')
      if results_info
        total_results_text = results_info.text.strip
        total_results_match = total_results_text.match(/Showing (\d\d?\d?)-(\d\d?\d?) of (\d\d?\d?)/)
        page_first = total_results_match[1].to_i
        page_last = total_results_match[2].to_i
        page_results = page_last - (page_first - 1)
        total_results = total_results_match[3]
        pager = page.at('p.pager.top')
        next_link = pager.at('a.next')
        if next_link
          next_link = next_link['href']
        end
        if VERBOSE
          puts "Getting results #{page_first} to #{page_last} of #{total_results}"
        end
      else
        page_first = page_last = page_results = total_results = next_link = nil
        if VERBOSE
          puts "One page of results"
        end
      end


      results_elements = page.search('li.searchresult')
      results = []
      results_elements.each do |result|
        address = result.at('p.address').text.strip
        council_reference = result.at('p.metaInfo').text.split('|').first.strip.split(" ").last
        application_path = result.at('a')['href']
        result_info = { council_reference: council_reference,
                        application_path: application_path,
                        address: address }
        results << result_info
      end
    rescue
      puts "parse_results_page failed" if VERBOSE
      if (retries += 1) < CONTENT_RETRIES
        sleep(3) && retry
      else
        puts "incomplete results"
      end
    end
    return { :page_first => page_first,
             :page_last => page_last,
             :page_results => page_results,
             :total_results => total_results,
             :next_link => next_link,
             :results => results }
  end

  def parse_application_summary(summary_uri)
    begin
      retries ||= 0
      page = get_page(summary_uri, {}, :get)
      council_reference = page.at('span.caseNumber').text.strip
      description = page.at('span.description').text.strip

      summary_info = { council_reference: council_reference,
                       description: description }
      details = page.at('table#simpleDetailsTable')
      details.search('tr').each do |row|
        key = row.at('th').text.strip.downcase.gsub(' ', '_').to_sym
        if key == :status
          summary_info[:status] = row.at('td').text.strip
        end
      end
    rescue
      puts "parse_application_summary failed #{summary_uri}" if VERBOSE
      if (retries += 1) < CONTENT_RETRIES
        sleep(3) && retry
      else
        puts "incomplete application dates #{summary_uri}"
      end
    end
    summary_info
  end

  def parse_application_details(details_uri)
    begin
      retries ||= 0
      page = get_page(details_uri, {}, :get)
      details = page.at('table#applicationDetails')

      details_info = { application_type: nil,
                       expected_decision_level: nil,
                       case_officer: nil,
                       community_council: nil,
                       ward: nil,
                       applicant_name: nil,
                       agent_name: nil,
                       agent_company_name: nil,
                       agent_address: nil,
                       environmental_assessment_requested: nil,
                       decision: nil,
                       actual_decision_level: nil,
                       expected_decision_level: nil }
      details.search('tr').each do |row|
        key = row.at('th').text.strip.downcase.gsub(' ', '_').to_sym
        if details_info.key?(key)
          details_info[key] = row.at('td').text.strip
        else
          raise "Unexpected details heading #{key}"
        end
      end
    rescue
      puts "parse_application_details failed #{details_uri}" if VERBOSE
      if (retries += 1) < CONTENT_RETRIES
        sleep(3) && retry
      else
        puts "incomplete application dates #{details_uri}"
      end
    end
    details_info
  end

  def parse_application_dates(dates_uri)
    begin
      retries ||= 0
      page = get_page(dates_uri, {}, :get)
      dates = page.at('table#simpleDetailsTable')
      dates_info = { application_received_date: nil,
                     application_validated_date: nil,
                     expiry_date: nil,
                     actual_committee_date: nil,
                     standard_consultation_expiry_date: nil,
                     decision_made_date: nil,
                     decision_issued_date: nil }
      dates.search('tr').each do |row|
        key = row.at('th').text.strip.downcase.gsub(' ', '_').to_sym
        if dates_info.key?(key)
          dates_info[key] = row.at('td').text.strip
        else
          raise "Unexpected details heading #{key}"
        end
      end
    rescue
      puts "parse_application_dates failed #{dates_uri}" if VERBOSE
      if (retries += 1) < CONTENT_RETRIES
        sleep(3) && retry
      else
        puts "incomplete application dates #{dates_uri}"
      end
    end
    dates_info
  end

  def initialize
    self.agent = Mechanize.new
  end

  def run

    # Submit weekly search form, get results
    page_data = []
    page = submit_search_form(DateTime.now, :monthly)
    page_info = parse_results_page(page)
    page_data << page_info
    next_link = page_info[:next_link]
    while next_link
      page = get_page(next_link, {}, :get)
      page_info = parse_results_page(page)
      page_data << page_info
      next_link = page_info[:next_link]
    end

    # Get info on each application
    page_data.each do |page_info|

      page_info[:results].each do |result|
        application_id = result[:application_path].split('=').last
        application_info = { application_id: application_id,
                             address: result[:address] }
        sleep 2
        application_info.merge!(parse_application_summary("#{SUMMARY_PATH}#{application_id}"))
        sleep 2
        application_info.merge!(parse_application_details("#{DETAILS_PATH}#{application_id}"))
        sleep 2
        application_info.merge!(parse_application_dates("#{DATES_PATH}#{application_id}"))
        puts application_info

        application_info[:info_url] = "#{HOST}#{SUMMARY_PATH}#{application_id}"
        application_info[:comment_url] = "#{HOST}#{MAKE_COMMENT_PATH}#{application_id}"
        application_info[:date_received] = application_info[:application_received_date]
        application_info[:date_scraped] = DateTime.now.strftime('%Y-%m-%d')

        ScraperWiki.save_sqlite([:council_reference], application_info)
      end
    end
  end

end

scraper = Scraper.new
scraper.run