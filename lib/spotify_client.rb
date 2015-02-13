require 'base64'
require 'excon'
require 'json'

require File.dirname(__FILE__) + '/spotify/utils'
require File.dirname(__FILE__) + '/spotify/exceptions'

module Spotify
  class Client
    BASE_URI = 'https://api.spotify.com'.freeze
    TOKEN_URI = 'https://accounts.spotify.com'.freeze

    attr_accessor :access_token

    # Initialize the client.
    #
    # @example
    #   client = Spotify::Client.new(:access_token => 'longtoken', retries: 0, raise_errors: true)
    #
    # @param [Hash] configuration.
    def initialize(config = {})
      @access_token  = config[:access_token]
      @raise_errors  = config[:raise_errors] || false
      @retries       = config[:retries] || 0
      @read_timeout  = config[:read_timeout] || 10
      @write_timeout = config[:write_timeout] || 10
      @connection    = Excon.new(BASE_URI, persistent: config[:persistent] || false)
    end

    def inspect
      vars = instance_variables.map { |v| "#{v}=#{instance_variable_get(v).inspect}" }.join(', ')
      "<#{self.class}: #{vars}>"
    end

    # Closes the connection underlying socket.
    # Use when you employ persistent connections and are done with your requests.
    def close_connection
      @connection.reset
    end

    # Requests for a new access token
    # It requires the refresh_token from the initial authorization
    def self.new_access_token(client_id, client_secret, refresh_token)
      connection = Excon.new(TOKEN_URI, persistent: false)
      authorization = Base64.strict_encode64 "#{client_id}:#{client_secret}"
      packet = {
        idempotent: true,
        expects: [200],
        method: 'post',
        path: '/api/token',
        read_timeout: @read_timeout,
        write_timeout: @write_timeout,
        retry_limit: @retries,
        headers: {
          'Content-Type' => 'application/x-www-form-urlencoded',
          'User-Agent'   => 'Spotify Ruby Client',
          'Authorization' => "Basic #{authorization}"
        },
        body: "grant_type=refresh_token&refresh_token=#{refresh_token}"
      }
      response = connection.request(packet)
      ::JSON.load(response.body)

    rescue Excon::Errors::NotFound => exception
      raise(ResourceNotFound, "Error: #{exception.message}")
    rescue Excon::Errors::BadRequest => exception
      raise(BadRequest, "Error: #{exception.message}")
    rescue Excon::Errors::Forbidden => exception
      raise(InsufficientClientScopeError, "Error: #{exception.message}")
    rescue Excon::Errors::Unauthorized => exception
      raise(AuthenticationError, "Error: #{exception.message}")
    rescue Excon::Errors::Error => exception
      # Catch all others errors. Samples:
      #
      # <Excon::Errors::SocketError: Connection refused - connect(2) (Errno::ECONNREFUSED)>
      # <Excon::Errors::InternalServerError: Expected([200, 204, 404]) <=> Actual(500 InternalServerError)>
      # <Excon::Errors::Timeout: read timeout reached>
      # <Excon::Errors::BadGateway: Expected([200]) <=> Actual(502 Bad Gateway)>
      raise(HTTPError, "Error: #{exception.message}")
    end

    def me
      run(:get, '/v1/me', [200])
    end

    # Get all tracks in the users "Your Music" library
    # Requires: user-library-read scope
    def library
      tracks = { 'items' => [] }
      path = '/v1/me/tracks'

      while path
        response = run(:get, path, [200])
        tracks['items'].concat(response.delete('items'))
        tracks.merge!(response)

        path = if response['next']
          response['next'].gsub(BASE_URI, '')
        else
          nil
        end
      end

      tracks
    end

    # Checks if the tracks are already saved in the user's "Your Music" library
    # Requires: user-library-read scope
    #
    # The returned array of booleans is in the same order in which the ids were specified
    def library?(track_ids)
      params = { ids: Array.wrap(track_ids).join(',') }
      run(:get, '/v1/me/tracks/contains', [200], params)
    end

    # Add tracks to the user's "Your Music" library
    # Requires: user-library-modify scope
    def add_library_tracks(track_ids)
      params = { ids: Array.wrap(track_ids)[0..99].join(',') }
      run(:post, "/v1/me/tracks", [200], params, false)
    end

    # Removes tracks from the user's "Your Music" library
    # Requires: user-library-modify scope
    def remove_library_tracks(track_ids)
      params = { ids: Array.wrap(track_ids)[0..99].join(',') }
      run(:delete, "/v1/me/tracks", [200], JSON.dump(tracks: tracks))
    end

    def user(user_id)
      run(:get, "/v1/users/#{user_id}", [200])
    end

    def user_playlists(user_id)
      run(:get, "/v1/users/#{user_id}/playlists", [200])
    end

    def user_playlist(user_id, playlist_id)
      run(:get, "/v1/users/#{user_id}/playlists/#{playlist_id}", [200])
    end

    def user_playlist_tracks(user_id, playlist_id, params = {})
      tracks = { 'items' => [] }
      path = "/v1/users/#{user_id}/playlists/#{playlist_id}/tracks"

      while path
        response = run(:get, path, [200], params)
        tracks['items'].concat(response.delete('items'))
        tracks.merge!(response)

        path = if response['next']
          response['next'].gsub(BASE_URI, '')
        else
          nil
        end
      end

      tracks
    end

    # Create a playlist for a Spotify user. The playlist will be empty until you add tracks.
    #
    # Requires playlist-modify-public for a public playlist.
    # Requires playlist-modify-private for a private playlist.
    def create_user_playlist(user_id, name, is_public = true)
      run(:post, "/v1/users/#{user_id}/playlists", [201], JSON.dump(name: name, public: is_public), false)
    end

    # Add an Array of track uris to an existing playlist.
    #
    # Adding tracks to a user's public playlist requires authorization of the playlist-modify-public scope;
    # adding tracks to a private playlist requires the playlist-modify-private scope.
    #
    # client.add_user_tracks_to_playlist('1181346016', '7i3thJWDtmX04dJhFwYb0x', %w(spotify:track:4iV5W9uYEdYUVa79Axb7Rh spotify:track:2lzEz3A3XIFyhMDqzMdcss))
    def add_user_tracks_to_playlist(user_id, playlist_id, uris = [], position = nil)
      params = { uris: Array.wrap(uris)[0..99].join(',') }
      if position
        params.merge!(position: position)
      end
      run(:post, "/v1/users/#{user_id}/playlists/#{playlist_id}/tracks", [201], params, false)
    end

    # Removes tracks from playlist
    #
    # client.remove_user_tracks_from_playlist('1181346016', '7i3thJWDtmX04dJhFwYb0x', [{ uri: spotify:track:4iV5W9uYEdYUVa79Axb7Rh, positions: [0]}])
    def remove_user_tracks_from_playlist(user_id, playlist_id, tracks)
      run(:delete, "/v1/users/#{user_id}/playlists/#{playlist_id}/tracks", [200], JSON.dump(tracks: tracks))
    end

    # Replaces all occurrences of tracks with what's in the playlist
    #
    # client.replace_user_tracks_in_playlist('1181346016', '7i3thJWDtmX04dJhFwYb0x', %w(spotify:track:4iV5W9uYEdYUVa79Axb7Rh spotify:track:2lzEz3A3XIFyhMDqzMdcss))
    def replace_user_tracks_in_playlist(user_id, playlist_id, tracks)
      run(:put, "/v1/users/#{user_id}/playlists/#{playlist_id}/tracks", [201], JSON.dump(uris: tracks))
    end

    # Removes all tracks in playlist
    #
    # client.truncate_user_playlist('1181346016', '7i3thJWDtmX04dJhFwYb0x')
    def truncate_user_playlist(user_id, playlist_id)
      replace_user_tracks_in_playlist(user_id, playlist_id, [])
    end

    def album(album_id)
      run(:get, "/v1/albums/#{album_id}", [200])
    end

    def album_tracks(album_id)
      run(:get, "/v1/albums/#{album_id}/tracks", [200])
    end

    def albums(album_ids)
      params = { ids: Array.wrap(album_ids).join(',') }
      run(:get, '/v1/albums', [200], params)
    end

    def track(track_id)
      run(:get, "/v1/tracks/#{track_id}", [200])
    end

    def tracks(track_ids)
      params = { ids: Array.wrap(track_ids).join(',') }
      run(:get, '/v1/tracks', [200], params)
    end

    def artist(artist_id)
      run(:get, "/v1/artists/#{artist_id}", [200])
    end

    def artists(artist_ids)
      params = { ids: Array.wrap(artist_ids).join(',') }
      run(:get, '/v1/artists', [200], params)
    end

    def artist_albums_full(artist_id)
      albums = { 'items' => [] }
      path = "/v1/artists/#{artist_id}/albums"

      while path
        response = run(:get, path, [200])
        albums['items'].concat(response.delete('items'))
        albums.merge!(response)

        path = if response['next']
          response['next'].gsub(BASE_URI, '')
        else
          nil
        end
      end

      albums
    end

    def artist_albums(artist_id)
      run(:get, "/v1/artists/#{artist_id}/albums", [200])
    end

    def search(entity, term)
      unless [:artist, :album, :track].include?(entity.to_sym)
        fail(ImplementationError, "entity needs to be either artist, album or track, got: #{entity}")
      end
      run(:get, '/v1/search', [200], q: term.to_s, type: entity)
    end

    # Get Spotify catalog information about an artist's top 10 tracks by country.
    #
    # +country_id+ is required. An ISO 3166-1 alpha-2 country code.
    def artist_top_tracks(artist_id, country_id)
      run(:get, "/v1/artists/#{artist_id}/top-tracks", [200], country: country_id)
    end

    def related_artists(artist_id)
      run(:get, "/v1/artists/#{artist_id}/related-artists", [200])
    end

    protected

    def run(verb, path, expected_status_codes, params = {}, idempotent = true)
      run!(verb, path, expected_status_codes, params, idempotent)
    rescue Error => e
      if @raise_errors
        raise e
      else
        false
      end
    end

    def run!(verb, path, expected_status_codes, params_or_body = nil, idempotent = true)
      packet = {
        idempotent: idempotent,
        expects: expected_status_codes,
        method: verb,
        path: path,
        read_timeout: @read_timeout,
        write_timeout: @write_timeout,
        retry_limit: @retries,
        headers: {
          'Content-Type' => 'application/json',
          'User-Agent'   => 'Spotify Ruby Client'
        }
      }
      if params_or_body.is_a?(Hash)
        packet.merge!(query: params_or_body)
      else
        packet.merge!(body: params_or_body)
      end

      if !@access_token.nil? && @access_token != ''
        packet[:headers].merge!('Authorization' => "Bearer #{@access_token}")
      end

      # puts "\033[31m [Spotify] HTTP Request: #{verb.upcase} #{BASE_URI}#{path} #{packet[:headers].inspect} \e[0m"
      response = @connection.request(packet)
      ::JSON.load(response.body)

    rescue Excon::Errors::NotFound => exception
      raise(ResourceNotFound, "Error: #{exception.message}")
    rescue Excon::Errors::BadRequest => exception
      raise(BadRequest, "Error: #{exception.message}")
    rescue Excon::Errors::Forbidden => exception
      raise(InsufficientClientScopeError, "Error: #{exception.message}")
    rescue Excon::Errors::Unauthorized => exception
      raise(AuthenticationError, "Error: #{exception.message}")
    rescue Excon::Errors::Error => exception
      # Catch all others errors. Samples:
      #
      # <Excon::Errors::SocketError: Connection refused - connect(2) (Errno::ECONNREFUSED)>
      # <Excon::Errors::InternalServerError: Expected([200, 204, 404]) <=> Actual(500 InternalServerError)>
      # <Excon::Errors::Timeout: read timeout reached>
      # <Excon::Errors::BadGateway: Expected([200]) <=> Actual(502 Bad Gateway)>
      raise(HTTPError, "Error: #{exception.message}")
    end
  end
end
