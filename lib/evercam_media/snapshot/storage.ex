defmodule EvercamMedia.Snapshot.Storage do
  use Calendar
  require Logger
  alias EvercamMedia.Util

  @root_dir Application.get_env(:evercam_media, :storage_dir)
  @seaweedfs Application.get_env(:evercam_media, :seaweedfs_url)

  def latest(camera_exid) do
    Path.wildcard("#{@root_dir}/#{camera_exid}/snapshots/*")
    |> Enum.reject(fn(x) -> String.match?(x, ~r/thumbnail.jpg/) end)
    |> Enum.reduce("", fn(type, acc) ->
      year = Path.wildcard("#{type}/????/") |> List.last
      month = Path.wildcard("#{year}/??/") |> List.last
      day = Path.wildcard("#{month}/??/") |> List.last
      hour = Path.wildcard("#{day}/??/") |> List.last
      last = Path.wildcard("#{hour}/??_??_???.jpg") |> List.last
      Enum.max_by([acc, "#{last}"], fn(x) -> String.slice(x, -27, 27) end)
    end)
  end

  def seaweedfs_save(camera_exid, timestamp, image, notes) do
    hackney = [pool: :seaweedfs_upload_pool]
    app_name = notes_to_app_name(notes)
    directory_path = construct_directory_path(camera_exid, timestamp, app_name, "")
    file_name = construct_file_name(timestamp)
    file_path = directory_path <> file_name
    HTTPoison.post!("#{@seaweedfs}#{file_path}", {:multipart, [{file_path, image, []}]}, [], hackney: hackney)
  end

  def seaweedfs_thumbnail_export(file_path, image) do
    path = String.replace_leading(file_path, "/storage", "")
    hackney = [pool: :seaweedfs_upload_pool]
    url = "#{@seaweedfs}#{path}"
    case HTTPoison.head(url, [], hackney: hackney) do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        HTTPoison.put!(url, {:multipart, [{path, image, []}]}, [], hackney: hackney)
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        HTTPoison.post!(url, {:multipart, [{path, image, []}]}, [], hackney: hackney)
      error ->
        raise "Upload for file path '#{file_path}' failed with: #{inspect error}"
    end
  end

  def exists_for_day?(camera_exid, from, to, timezone) do
    hours = hours(camera_exid, from, to, timezone)
    !Enum.empty?(hours)
  end

  def hours(camera_exid, from, to, timezone) do
    url_base = "#{@seaweedfs}/#{camera_exid}/snapshots"
    apps_list = get_camera_apps_list(camera_exid)
    from_date = Strftime.strftime!(from, "%Y/%m/%d")
    to_date = Strftime.strftime!(to, "%Y/%m/%d")

    from_hours =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{from_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(hour) -> parse_hour(from.year, from.month, from.day, "#{hour}:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> DateTime.before?(datetime, from) end)

    to_hours =
      apps_list
      |> Enum.flat_map(fn(app) -> request_from_seaweedfs("#{url_base}/#{app}/#{to_date}/", "Subdirectories", "Name") end)
      |> Enum.uniq
      |> Enum.map(fn(hour) -> parse_hour(to.year, to.month, to.day, "#{hour}:00:00", timezone) end)
      |> Enum.reject(fn(datetime) -> DateTime.after?(datetime, to) end)

    Enum.concat(from_hours, to_hours)
    |> Enum.map(fn(datetime) -> datetime.hour end)
    |> Enum.sort
  end

  def hour(camera_exid, hour) do
    url_base = "#{@seaweedfs}/#{camera_exid}/snapshots"
    apps_list = get_camera_apps_list(camera_exid)
    hour_datetime = Strftime.strftime!(hour, "%Y/%m/%d/%H")
    dir_paths = lookup_dir_paths(camera_exid, apps_list, hour)

    apps_list
    |> Enum.map(fn(app_name) -> {app_name, request_from_seaweedfs("#{url_base}/#{app_name}/#{hour_datetime}/?limit=3600", "Files", "name")} end)
    |> Enum.reject(fn({_app_name, files}) -> files == [] end)
    |> Enum.flat_map(fn({app_name, files}) ->
      Enum.map(files, fn(file_path) ->
        Map.get(dir_paths, app_name)
        |> construct_snapshot_record(file_path, app_name)
      end)
    end)
  end

  def seaweedfs_load_range(camera_exid, from) do
    snapshots =
      camera_exid
      |> get_camera_apps_list
      |> Enum.flat_map(fn(app) -> do_seaweedfs_load_range(camera_exid, from, app) end)
      |> Enum.sort_by(fn(snapshot) -> snapshot.created_at end)
    {:ok, snapshots}
  end

  defp do_seaweedfs_load_range(camera_exid, from, app_name) do
    directory_path = construct_directory_path(camera_exid, from, app_name, "")

    request_from_seaweedfs("#{@seaweedfs}#{directory_path}?limit=3600", "Files", "name")
    |> Enum.map(fn(file_path) -> construct_snapshot_record(directory_path, file_path, app_name) end)
  end

  defp get_camera_apps_list(camera_exid) do
    request_from_seaweedfs("#{@seaweedfs}/#{camera_exid}/snapshots/", "Subdirectories", "Name")
  end

  defp request_from_seaweedfs(url, type, attribute) do
    hackney = [pool: :seaweedfs_download_pool]
    with {:ok, response} <- HTTPoison.get(url, [], hackney: hackney),
         %HTTPoison.Response{status_code: 200, body: body} <- response,
         {:ok, data} <- Poison.decode(body),
         true <- is_list(data[type]) do
      Enum.map(data[type], fn(item) -> item[attribute] end)
    else
      _ -> []
    end
  end

  def thumbnail_load(camera_exid) do
    disk_thumbnail_load(camera_exid)
  end

  def disk_thumbnail_load(camera_exid) do
    "#{@root_dir}/#{camera_exid}/snapshots/thumbnail.jpg"
    |> File.open([:read, :binary, :raw], fn(file) -> IO.binread(file, :all) end)
    |> case do
      {:ok, content} -> {:ok, content}
      {:error, _error} -> {:error, Util.unavailable}
    end
  end

  def save(camera_exid, _timestamp, image, "Evercam Thumbnail"), do: thumbnail_save(camera_exid, image)
  def save(camera_exid, timestamp, image, notes) do
    seaweedfs_save(camera_exid, timestamp, image, notes)
    thumbnail_save(camera_exid, image)
  end

  defp thumbnail_save(camera_exid, image) do
    "#{@root_dir}/#{camera_exid}/snapshots/thumbnail.jpg"
    |> File.open([:write, :binary, :raw], fn(file) -> IO.binwrite(file, image) end)
    |> case do
      {:error, :enoent} ->
        File.mkdir_p!("#{@root_dir}/#{camera_exid}/snapshots/")
        thumbnail_save(camera_exid, image)
      _ -> :noop
    end
  end

  def load(camera_exid, snapshot_id, notes) do
    app_name = notes_to_app_name(notes)
    timestamp =
      snapshot_id
      |> String.split("_")
      |> List.last
      |> Util.snapshot_timestamp_to_unix
    case seaweedfs_load(camera_exid, timestamp, app_name) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :not_found} -> disk_load(camera_exid, timestamp, app_name)
    end
  end

  defp disk_load(camera_exid, timestamp, app_name) do
    directory_path = construct_directory_path(camera_exid, timestamp, app_name)
    file_name = construct_file_name(timestamp)
    File.open("#{directory_path}#{file_name}", [:read, :binary, :raw], fn(file) ->
      IO.binread(file, :all)
    end)
  end

  defp seaweedfs_load(camera_exid, timestamp, app_name) do
    directory_path = construct_directory_path(camera_exid, timestamp, app_name, "")
    file_name = construct_file_name(timestamp)
    file_path = directory_path <> file_name
    case HTTPoison.get("#{@seaweedfs}#{file_path}", [], hackney: [pool: :seaweedfs_download_pool]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: snapshot}} ->
        {:ok, snapshot}
      _error ->
        {:error, :not_found}
    end
  end

  def cleanup(cloud_recording) do
    unless cloud_recording.storage_duration == -1 do
      camera_exid = cloud_recording.camera.exid
      seconds_to_day_before_expiry = (cloud_recording.storage_duration) * (24 * 60 * 60) * (-1)
      day_before_expiry =
        DateTime.now_utc
        |> DateTime.advance!(seconds_to_day_before_expiry)
        |> DateTime.to_date

      Logger.info "[#{camera_exid}] [snapshot_delete_disk]"
      Path.wildcard("#{@root_dir}/#{camera_exid}/snapshots/recordings/????/??/??/")
      |> Enum.each(fn(path) -> delete_if_expired(camera_exid, path, day_before_expiry) end)
    end
  end

  defp delete_if_expired(camera_exid, path, day_before_expiry) do
    date =
      path
      |> String.replace_leading("#{@root_dir}/#{camera_exid}/snapshots/recordings/", "")
      |> String.replace("/", "-")
      |> Date.Parse.iso8601!

    if Calendar.Date.before?(date, day_before_expiry) do
      Logger.info "[#{camera_exid}] [snapshot_delete_disk] [#{Date.Format.iso8601(date)}]"
      dir_path = Strftime.strftime!(date, "#{@root_dir}/#{camera_exid}/snapshots/recordings/%Y/%m/%d")
      Porcelain.shell("ionice -c 3 find '#{dir_path}' -exec sleep 0.01 \\; -delete")
    end
  end

  def construct_directory_path(camera_exid, timestamp, app_dir, root_dir \\ @root_dir) do
    timestamp
    |> DateTime.Parse.unix!
    |> Strftime.strftime!("#{root_dir}/#{camera_exid}/snapshots/#{app_dir}/%Y/%m/%d/%H/")
  end

  def construct_file_name(timestamp) do
    timestamp
    |> DateTime.Parse.unix!
    |> Strftime.strftime!("%M_%S_%f")
    |> format_file_name
  end

  defp construct_snapshot_record(directory_path, file_path, app_name) do
    %{
      created_at: parse_file_timestamp(directory_path, file_path),
      notes: app_name_to_notes(app_name),
      motion_level: nil
    }
  end

  defp parse_file_timestamp(directory_path, file_path) do
    [_, _, _, year, month, day, hour] = String.split(directory_path, "/", trim: true)
    [minute, second, _] = String.split(file_path, "_")

    DateTime.Parse.rfc3339_utc("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")
    |> elem(1)
    |> DateTime.Format.unix
  end

  defp parse_hour(year, month, day, time, timezone) do
    month = String.rjust("#{month}", 2, ?0)
    day = String.rjust("#{day}", 2, ?0)

    "#{year}-#{month}-#{day}T#{time}Z"
    |> Calendar.DateTime.Parse.rfc3339_utc
    |> elem(1)
    |> Calendar.DateTime.shift_zone!(timezone)
  end

  def format_file_name(<<file_name::bytes-size(6)>>) do
    "#{file_name}000" <> ".jpg"
  end

  def format_file_name(<<file_name::bytes-size(7)>>) do
    "#{file_name}00" <> ".jpg"
  end

  def format_file_name(<<file_name::bytes-size(9), _rest :: binary>>) do
    "#{file_name}" <> ".jpg"
  end

  def lookup_dir_paths(camera_exid, apps_list, datetime) do
    timestamp = DateTime.Format.unix(datetime)

    Enum.reduce(apps_list, %{}, fn(app_name, map) ->
      dir_path = construct_directory_path(camera_exid, timestamp, app_name, "")
      Map.put(map, app_name, dir_path)
    end)
  end

  def app_name_to_notes(name) do
    case name do
      "recordings" -> "Evercam Proxy"
      "thumbnail" -> "Evercam Thumbnail"
      "timelapse" -> "Evercam Timelapse"
      "snapmail" -> "Evercam SnapMail"
      _ -> "User Created"
    end
  end

  def notes_to_app_name(notes) do
    case notes do
      "Evercam Proxy" -> "recordings"
      "Evercam Thumbnail" -> "thumbnail"
      "Evercam Timelapse" -> "timelapse"
      "Evercam SnapMail" -> "snapmail"
      _ -> "archives"
    end
  end
end
