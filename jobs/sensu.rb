#!/usr/bin/env ruby

require 'net/http'
require 'json'
require './logging'

app_name = 'fleximon'
$logger = MyLoggerMiddleware.new(STDOUT, app_name)
use MyLoggerMiddleware, $logger

$logger.debug("starting app: %s" % app_name)

begin
  # connection details to environments
  env_file = File.read('environments.json')
  environments = JSON.parse(env_file)

  # columns config for teamviews
  columns_file = File.read('columns.json')
  columns = JSON.parse(columns_file)

rescue Exception => config
  $logger.error('config problems, exiting...', config.class, config.message,
                config.backtrace)
  exit false
end

def get_status(status)
  case status
  when 0
    return 'ok'
  when 1
    return 'warning'
  when 2
    return 'critical'
  else
    return 'unknown'
  end
end

SCHEDULER.every '60s', first_in: 0 do |_job|
  critical_count = 0
  warning_count = 0
  unknown_count = 0
  client_warning = []
  client_critical = []
  table_data = []
  hrows = [{ cols: [] }]

  # fetch data from sensu API
  def get_data(api, endpoint, user, pass)
    $logger.debug('getting data for %s from %s' % [endpoint, api])
    uri = URI(api + endpoint)
    req = Net::HTTP::Get.new(uri)
    auth = (user.empty? || pass.empty?) ? false : true
    req.basic_auth user, pass if auth
    begin
      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(req)
      end

    rescue Exception => conn
      $logger.error('Error connecting to %s' % api, conn.class, conn.message,
                    conn.backtrace)
      return
    end

    begin
      JSON.parse(response.body)
    rescue Exception => json_err
      $logger.error('JSON problems', json_err.class, json_err.message,
                    json_err.backtrace)
      return
    end
  end

  # associate column name with hash entry
  def get_assoc(column_name, entry)
    assoc = {}
    assoc['hostname'] = entry['client']['name']
    assoc['check'] = entry['check']['name']
    assoc['output'] = entry['check']['output']
    assoc['team'] = entry['check']['team']
    assoc['category'] = entry['check']['category']

    assoc[column_name]
  end

  events = []
  # iterrate through each envionments in the config
  # and pull data for each
  environments['config'].each do |_key, value|
    endpoint = '/events'
    port = value['port']
    user = value['user']
    pass = value['password']
    path = value['path'].nil? ? '' : value['path']
    api = 'http://' + value['host'] + ':' + port + path
    current_env = get_data(api, endpoint, user, pass)
    events.push(*current_env)
  end

  warn = []
  crit = []
  # status = get_data(SENSU_API_ENDPOINT, '/status',

  columns['config']['default'].each do |column|
    hrows[0][:cols].insert(-1, value: column)
  end

  # for each event...
  events.each_with_index do |event, _event_index|
    status = event['check']['status']
    status_string = get_status(status)
    event_var = { cols: [] }

    # for each column....
    columns['config']['default'].each_with_index do |column, _column_index|
      data = get_assoc(column, event)
      data = data.nil? ? '' : data.chomp # remove tailing whitespace

      # add column to event var
      column_var = { class: status_string, value: data }
      event_var[:cols].insert(-1, column_var)
    end
    # add complete row
    table_data.insert(-1, event_var)

    # increment alarm count for different status type
    if status == 1
      warn.push(event)
      warning_count += 1
    elsif status == 2
      crit.push(event)
      critical_count += 1
    elsif status > 2 # status 3 and above == unknown
      unknown_count += 1
    end
  end

  # update warning count
  unless warn.empty?
    warn.each do |entry|
      client_warning.push(label: entry['client']['name'],
                          value: entry['check']['name'])
    end
  end

  # update critical count
  unless crit.empty?
    crit.each.with_index do |entry, _index|
      client_critical.push(label: entry['client']['name'],
                           value: entry['check']['name'])
    end
  end

  status = if critical_count > 0
             'red'
           elsif warning_count > 0
             'yellow'
           else
             'green'
           end

  # Send all collected data to dashboard
  send_event('sensu-status',
             criticals_tmp: critical_count,
             warnings_tmp: warning_count,
             unknowns_tmp: unknown_count,
             status: status)

  send_event('sensu-warn-list', items: client_warning)
  send_event('sensu-crit-list', items: client_critical)

  # dump data into temporary array to be sorted at runtime
  # depending on team query string provided in URL
  send_event('sensu-table', hrows_tmp: hrows, rows_tmp: table_data)

end
