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
      if method == :get
        page = agent.get(url)
      else
        page = agent.post(url, data)
      end
      if WRITE_CACHE
        File.open(cache_path, 'w'){ |file| file.write(page.body) }
      end
    end
    return page
  end

  def submit_weekly_search_form(date)
    # Read in a page
    weekly_search_path = '/online-applications/search.do?action=weeklyList'
    page = get_page(weekly_search_path, {}, :get)
    weekly_list_form = page.form('searchCriteriaForm')
    weekly_list_form.action = "#{HOST}#{weekly_list_form.action}"
    weekly_list_form['searchType'] = 'Application'
    weekly_list_form['ward'] = 'LANE'
    previous_monday = date - date.wday + 1
    weekly_list_form['week'] = previous_monday.strftime('%d %b %Y')
    weekly_list_form['dateType'] = 'DC_Validated'

    if VERBOSE
      puts "Submitting weekly search form"
    end
    agent.submit(weekly_list_form, weekly_list_form.buttons.first)
  end

  def parse_results_page(page)
    total_results_text = page.at('span.showing').text.strip
    total_results_match = total_results_text.match(/Showing (\d\d?\d?)-(\d\d?\d?) of (\d\d?\d?)/)
    page_first = total_results_match[1].to_i
    page_last = total_results_match[2].to_i
    page_results = page_last - (page_first - 1)
    total_results = total_results_match[3]

    if VERBOSE
      puts "Getting results #{page_first} to #{page_last} of #{total_results}"
    end
    pager = page.at('p.pager.top')
    next_link = pager.at('a.next')
    if next_link
      next_link = next_link['href']
    end
    results_elements = page.search('li.searchresult')
    results = []
    results_elements.each do |result|
      address = result.at('p.address').text.strip
      reference_no = result.at('p.metaInfo').text.split('|').first.strip.split(" ").last
      application_path = result.at('a')['href']
      result_info = { :reference_no => reference_no,
                      :application_path => application_path,
                      :address => address }
      results << result_info
    end
    return { :page_first => page_first,
             :page_last => page_last,
             :page_results => page_results,
             :total_results => total_results,
             :next_link => next_link,
             :results => results }
  end

  def parse_application_summary(summary_uri)
    page = get_page(summary_uri, {}, :get)
    reference_no = page.at('span.caseNumber').text.strip
    description = page.at('span.description').text.strip
    { reference_no: reference_no,
      description: description }
  end

  def parse_application_details(details_uri)
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
                     environmental_assessment_requested: nil }

    details.search('tr').each do |row|
      key = row.at('th').text.strip.downcase.gsub(' ', '_').to_sym
      if details_info.key?(key)
        details_info[key] = row.at('td').text.strip
      else
        raise "Unexpected details heading #{key}"
      end
    end
    details_info
  end

  def parse_application_dates(dates_uri)
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
    dates_info
  end

  def initialize
    self.agent = Mechanize.new
  end

  def run
    agent.cookie_jar.load('cookies')

    # Submit weekly search form, get results
    page_data = []
    page = submit_weekly_search_form(DateTime.now)
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
        application_info = { application_id: application_id }
        sleep 2
        application_info.merge!(parse_application_summary("#{SUMMARY_PATH}#{application_id}"))
        sleep 2
        application_info.merge!(parse_application_details("#{DETAILS_PATH}#{application_id}"))
        sleep 2
        application_info.merge!(parse_application_dates("#{DATES_PATH}#{application_id}"))
        puts application_info
        ScraperWiki.save_sqlite([:reference_no], application_info)
      end
    end

    agent.cookie_jar.save_as('cookies', :session => true, :format => :yaml)

  end

end

scraper = Scraper.new
scraper.run