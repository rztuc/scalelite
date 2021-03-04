# frozen_string_literal: true

require 'concurrent-ruby'

desc 'Run a polling process to continually monitor servers and meetings'
task :poll, [:interval] => :environment do |_t, args|
  args.with_defaults(interval: 60.seconds)
  interval = args.interval.to_f
  Rails.logger.info("Running poller with interval #{interval}")

  poll_all_task = Rake::Task['poll:all']
  loop do
    begin
      poll_all_task.invoke
    rescue Redis::CannotConnectError => e
      Rails.logger.warn(e)
    end

    sleep(interval)

    poll_all_task.reenable
    poll_all_task.prerequisite_tasks.each(&:reenable)
  end
rescue SignalException => e
  Rails.logger.info("Exiting poller on signal: #{e}")
end

namespace :poll do
  desc 'Check all servers to update their online and load status'
  task servers: :environment do
    include ApiHelper

    Rails.logger.debug('Polling servers')
    pool = Concurrent::FixedThreadPool.new(Rails.configuration.x.poller_threads.to_i - 1, name: 'sync-server-data')
    tasks = Server.all.map do |server|
      Concurrent::Promises.future_on(pool) do
        Rails.logger.debug { "Polling Server id=#{server.id}" }
        resp = get_post_req(encode_bbb_uri('getMeetings', server.url, server.secret))
        meetings = resp.xpath('/response/meetings/meeting')

        total_attendees = 0
        server_users = 0
        video_streams = 0
        users_in_largest_meeting = 0

        load_min_user_count = Rails.configuration.x.load_min_user_count
        x_minutes_ago = Rails.configuration.x.load_join_buffer_time.ago
        weight_meetings = Rails.configuration.x.weight_meetings
        weight_users = Rails.configuration.x.weight_users
        weight_audio_rx = Rails.configuration.x.weight_audio_rx
        weight_audio_tx = Rails.configuration.x.weight_audio_tx
        weight_video_rx = Rails.configuration.x.weight_video_rx
        weight_video_tx = Rails.configuration.x.weight_video_tx

        load = 0.0
        meetings.each do |meeting|
          created_time = Time.zone.at(meeting.xpath('.//createTime').text.to_i / 1000)
          actual_attendees = meeting.xpath('.//participantCount').text.to_i + meeting.xpath('.//moderatorCount').text.to_i
          count = meeting.at_xpath('participantCount')
          users = count.present? ? count.text.to_i : 0
          server_users += users
          users_in_largest_meeting = users if users > users_in_largest_meeting
          streams = meeting.at_xpath('videoCount')
          video_streams += streams.present? ? streams.text.to_i : 0

          next if meeting.xpath('.//isBreakout').text.eql?('true')

          attendees = if created_time > x_minutes_ago
                        [actual_attendees, load_min_user_count].max
                      else
                        actual_attendees
                      end
          audio = meeting.at('voiceParticipantCount')&.content.to_i
          video = meeting.at('videoCount')&.content.to_i
          load += weight_meetings * 1
          # Account for users in main rooms only - they join two rooms at the same time.
          load += weight_users * attendees if meeting.xpath('.//isBreakout').text.eql?('false')
          # Audio is mixed server-side -> Only one downstream per user
          load += weight_audio_rx * audio
          load += weight_audio_tx * attendees if audio
          # Video is NOT mixed server-side -> One downstream per user per video
          load += weight_video_rx * video
          load += weight_video_tx * attendees * video
        end
        load *= server.load_multiplier.nil? ? 1.0 : server.load_multiplier.to_d

        # Reset unhealthy counter so that only consecutive unhealthy calls are counted
        server.reset_unhealthy_counter

        if server.online
          # Update the load if the server is currently online
          server.load = load
        else
          # Only bring the server online if the number of successful requests is >= the acceptable threshold
          next if server.increment_healthy < Rails.configuration.x.server_healthy_threshold

          Rails.logger.info("Server id=#{server.id} is healthy. Bringing back online...")
          server.reset_counters
          server.load = load
          server.online = true
        end

        server.state = 'disabled' if server.cordoned? && server.load.to_f.zero?
        server.meetings = meetings.size
        server.users = server_users
        server.largest_meeting = users_in_largest_meeting
        server.videos = video_streams
      rescue StandardError => e
        Rails.logger.warn("Failed to get server id=#{server.id} status: #{e}")

        # Reset healthy counter so that only consecutive healthy calls are counted
        server.reset_healthy_counter

        next unless server.online # Only check healthiness if server is currently online

        # Only take the server offline if the number of failed requests is >= the acceptable threshold
        next if server.increment_unhealthy < Rails.configuration.x.server_unhealthy_threshold

        Rails.logger.warn("Server id=#{server.id} is unhealthy. Panicking and setting offline...")

        meetings = Meeting.all.select { |m| m.server_id == server.id }
        meetings.each do |meeting|
          puts("Clearing Meeting id=#{meeting.id}")
          moderator_pw = meeting.try(:moderator_pw)
          meeting.destroy!
          get_post_req(encode_bbb_uri('end', server.url, server.secret, meetingID: meeting.id, password: moderator_pw))
        rescue ApplicationRedisRecord::RecordNotDestroyed => e
          raise("ERROR: Could not destroy meeting id=#{meeting.id}: #{e}")
        rescue StandardError => e
          puts("WARNING: Could not end meeting id=#{meeting.id}: #{e}")
        end

        server.reset_counters
        server.load = nil
        server.online = false
        server.meetings = 0
        server.users = 0
        server.largest_meeting = 0
        server.videos = 0
      ensure
        begin
          server.save!
          Rails.logger.info(
            "Server id=#{server.id} #{server.online ? 'online' : 'offline'} " \
            "load: #{server.load.nil? ? 'unavailable' : server.load}"
          )
        rescue ApplicationRedisRecord::RecordNotSaved => e
          Rails.logger.warn("Unable to update Server id=#{server.id}: #{e}")
        end
      end
    end
    begin
      Concurrent::Promises.zip_futures_on(pool, *tasks).wait!(Rails.configuration.x.poller_wait_timeout)
    rescue StandardError => e
      Rails.logger.warn("Error #{e}")
    end
    pool.shutdown
    pool.wait_for_termination(5) || pool.kill
  end

  desc 'Check all meetings to clear ended meetings'
  task meetings: :environment do
    include ApiHelper

    Rails.logger.debug('Polling meetings')
    pool = Concurrent::FixedThreadPool.new(Rails.configuration.x.poller_threads.to_i - 1, name: 'sync-meeting-data')
    tasks = Meeting.all.map do |meeting|
      Concurrent::Promises.future_on(pool) do
        server = meeting.server
        Rails.logger.debug { "Polling Meeting id=#{meeting.id} on Server id=#{server.id}" }
        get_post_req(encode_bbb_uri('getMeetingInfo', server.url, server.secret, meetingID: meeting.id))
      rescue BBBErrors::BBBError => e
        unless e.message_key == 'notFound'
          Rails.logger.warn("Unexpected BigBlueButton error polling Meeting id=#{meeting.id} on Server id=#{server.id}: #{e}")
          next
        end

        begin
          meeting.destroy!
          Rails.logger.info("Meeting id=#{meeting.id} on Server id=#{server.id} has ended")
        rescue ApplicationRedisRecord::RecordNotSaved => e
          Rails.logger.warn("Unable to destroy meeting id=#{meeting.id}: #{e}")
        end
      rescue StandardError => e
        Rails.logger.warn("Failed to check meeting id=#{meeting.id} status: #{e}")
      end
    end
    begin
      Concurrent::Promises.zip_futures_on(pool, *tasks).wait!(Rails.configuration.x.poller_wait_timeout)
    rescue StandardError => e
      Rails.logger.warn("Error #{e}")
    end

    pool.shutdown
    pool.wait_for_termination(5) || pool.kill
  end

  desc 'Check the BBB version of all servers'
  task versions: :environment do
    include ApiHelper

    Rails.logger.debug('Checking versions')
    pool = Concurrent::FixedThreadPool.new(Rails.configuration.x.poller_threads.to_i - 1, name: 'sync-version-data')
    tasks = Server.all.map do |server|
      Concurrent::Promises.future_on(pool) do
        Rails.logger.debug { "Checking Version of id=#{server.id}" }
        bbb_version = get_post_req(encode_bbb_uri('', server.url, server.secret)).xpath('/response/bbbVersion').text
        server.bbb_version = bbb_version
      rescue StandardError => e
        Rails.logger.warn("Unexpected error when checking version of server id=#{server.id}: #{e}")
      ensure
        begin
          server.save!
        rescue ApplicationRedisRecord::RecordNotSaved => e
          Rails.logger.warn("Unable to update Server id=#{server.id}: #{e}")
        end
      end
    end
    begin
      Concurrent::Promises.zip_futures_on(pool, *tasks).wait!(Rails.configuration.x.poller_wait_timeout)
    rescue StandardError => e
      Rails.logger.warn("Error #{e}")
    end
    pool.shutdown
    pool.wait_for_termination(5) || pool.kill
  end

  desc 'Run all pollers once'
  multitask all: [:servers, :meetings, :versions]
end
