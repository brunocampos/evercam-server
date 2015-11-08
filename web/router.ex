defmodule EvercamMedia.Router do
  use EvercamMedia.Web, :router

  pipeline :browser do
    plug :accepts, ["html", "json", "jpg"]
    plug :fetch_session
    plug :fetch_flash
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug EvercamMedia.AuthenticationPlug
  end

  pipeline :onvif do
    plug EvercamMedia.ONVIFAccessPlug
  end

  scope "/", EvercamMedia do
    pipe_through :browser

    get "/", PageController, :index

    post "/v1/cameras/test", SnapshotController, :test
    get "/v1/cameras/:id/live/snapshot", SnapshotController, :show
    get "/v1/cameras/:id/live/snapshot/last", SnapshotController, :show_last
    get "/v1/cameras/:id/live/snapshot/previous", SnapshotController, :show_previous
    post "/v1/cameras/:id/recordings/snapshots", SnapshotController, :create

    get "/v1/cameras/:id/touch", CameraController, :update

    get "/live/:camera_id/index.m3u8", StreamController, :hls
    get "/live/:camera_id/:filename", StreamController, :ts
    get "/on_play", StreamController, :rtmp
  end

  scope "/v1", EvercamMedia do
    pipe_through :api

    post "/users", UserController, :create

    scope "/" do
      pipe_through :auth

      get "/users/:id", UserController, :show
      put "/users/:id", UserController, :update
    end
    
    scope "/" do
      pipe_through :onvif
      
      get "/cameras/:id/ptz/status", ONVIFPTZController, :status
      get "/cameras/:id/ptz/presets", ONVIFPTZController, :presets
      get "/cameras/:id/ptz/nodes", ONVIFPTZController, :nodes
      get "/cameras/:id/ptz/configurations", ONVIFPTZController, :configurations
      post "/cameras/:id/ptz/home", ONVIFPTZController, :home
      post "/cameras/:id/ptz/home/set", ONVIFPTZController, :sethome
      post "/cameras/:id/ptz/presets/:preset_token", ONVIFPTZController, :setpreset
      post "/cameras/:id/ptz/presets/create/:preset_name", ONVIFPTZController, :createpreset
      post "/cameras/:id/ptz/presets/go/:preset_token", ONVIFPTZController, :gotopreset
      post "/cameras/:id/ptz/continuous/start/:direction", ONVIFPTZController, :continuousmove
      post "/cameras/:id/ptz/continuous/zoom/:mode", ONVIFPTZController, :continuouszoom
      post "/cameras/:id/ptz/continuous/stop", ONVIFPTZController, :stop
      post "/cameras/:id/ptz/relative", ONVIFPTZController, :relativemove

      get "/devices/:id/onvif/v20/GetDeviceInformation", ONVIFDeviceManagementController, :invoke_no_params
      get "/devices/:id/onvif/v20/GetNetworkInterfaces", ONVIFDeviceManagementController, :invoke_no_params
      get "/devices/:id/onvif/v20/GetCapabilities", ONVIFDeviceManagementController, :invoke_no_params

      get "/devices/:id/onvif/v20/GetProfiles", ONVIFMediaController, :invoke_no_params
      get "/devices/:id/onvif/v20/GetServiceCapabilities", ONVIFMediaController, :invoke_no_params
      get "/devices/:id/onvif/v20/GetSnapshotUri/:profile", ONVIFMediaController, :get_snapshot_uri
    end

  end
end
