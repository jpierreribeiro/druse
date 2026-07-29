package main

import (
	"net/http"
	"os"
	"strconv"
	"sync/atomic"

	"github.com/gofiber/fiber/v3"
	"druse-bench/application-matrix-go/workload"
)

func main() {
	app := fiber.New()

	app.Get("/health", func(c fiber.Ctx) error {
		c.Type("text", "utf-8")
		return c.SendString("ok")
	})
	app.Get("/json/small", func(c fiber.Ctx) error {
		return c.JSON(workload.Small)
	})
	app.Get("/json/medium", func(c fiber.Ctx) error {
		return c.JSON(workload.Medium)
	})
	app.Post("/json/echo", func(c fiber.Ctx) error {
		var input workload.SmallDocument
		if err := workload.DecodeStrict(c.Body(), &input); err != nil {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid_json"})
		}
		return c.JSON(input)
	})
	app.Post("/json/medium", func(c fiber.Ctx) error {
		var input workload.MediumDocument
		if err := workload.DecodeStrict(c.Body(), &input); err != nil {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid_json"})
		}
		return c.JSON(input)
	})
	app.Post("/json/medium/decode", func(c fiber.Ctx) error {
		var input workload.MediumDocument
		if err := workload.DecodeStrict(c.Body(), &input); err != nil {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid_json"})
		}
		return c.SendStatus(http.StatusNoContent)
	})

	var requestID atomic.Uint64
	api := app.Group("/api")
	api.Use(func(c fiber.Ctx) error {
		id := requestID.Add(1)
		c.Set("X-Request-Id", strconv.FormatUint(id, 10))
		return c.Next()
	})
	api.Use(func(c fiber.Ctx) error { return c.Next() })
	api.Use(func(c fiber.Ctx) error { return c.Next() })
	api.Use(func(c fiber.Ctx) error {
		c.Locals("account_id", 7)
		return c.Next()
	})
	api.Get("/users/:id", func(c fiber.Ctx) error {
		accountID, _ := c.Locals("account_id").(int)
		response, err := workload.ParseRouted(c.Params("id"), c.Query("verbose"), accountID)
		if err != nil {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid_field"})
		}
		return c.JSON(response)
	})

	address := ":8081"
	if len(os.Args) > 1 {
		address = ":" + os.Args[1]
	}
	if err := app.Listen(address, fiber.ListenConfig{DisableStartupMessage: true}); err != nil {
		panic(err)
	}
}
