package main

import (
	"context"
	"encoding/json"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

type response struct {
	Env string `json:"env"`
	PR  string `json:"pr"`
	Msg string `json:"msg"`
}

func handler(_ context.Context, _ events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	body, err := json.Marshal(response{
		Env: os.Getenv("DIALED_ENV"),
		PR:  os.Getenv("DIALED_PR"),
		Msg: "hello from DIALED",
	})
	if err != nil {
		return events.APIGatewayV2HTTPResponse{StatusCode: 500, Body: err.Error()}, nil
	}
	return events.APIGatewayV2HTTPResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(body),
	}, nil
}

func main() {
	lambda.Start(handler)
}
