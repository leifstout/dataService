local server = require(script.DataServiceServer)
local client = require(script.DataServiceClient)

export type Server = server.DataServiceServer
export type Client = client.DataServiceClient

return {
	server = server,
	client = client,
}
