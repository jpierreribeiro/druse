package main

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"

	"github.com/gin-gonic/gin"
	"druse-bench/application-matrix-go/workload"
)

func main() {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()

	router.GET("/health", func(c *gin.Context) {
		c.Data(http.StatusOK, "text/plain; charset=utf-8", []byte("ok"))
	})
	router.GET("/json/small", func(c *gin.Context) {
		c.JSON(http.StatusOK, workload.Small)
	})
	router.GET("/json/medium", func(c *gin.Context) {
		c.JSON(http.StatusOK, workload.Medium)
	})
	router.POST("/json/echo", func(c *gin.Context) {
		var input workload.SmallDocument
		if err := workload.DecodeStrict(readBody(c), &input); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_json"})
			return
		}
		c.JSON(http.StatusOK, input)
	})
	router.POST("/json/medium", func(c *gin.Context) {
		var input workload.MediumDocument
		if err := workload.DecodeStrict(readBody(c), &input); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_json"})
			return
		}
		c.JSON(http.StatusOK, input)
	})
	router.POST("/json/medium/decode", func(c *gin.Context) {
		var input workload.MediumDocument
		if err := workload.DecodeStrict(readBody(c), &input); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_json"})
			return
		}
		c.Status(http.StatusNoContent)
	})

	var requestID atomic.Uint64
	api := router.Group("/api")
	api.Use(func(c *gin.Context) {
		id := requestID.Add(1)
		c.Header("X-Request-Id", strconv.FormatUint(id, 10))
		c.Next()
	})
	api.Use(func(c *gin.Context) { c.Next() })
	api.Use(func(c *gin.Context) { c.Next() })
	api.Use(func(c *gin.Context) {
		c.Set("account_id", 7)
		c.Next()
	})
	api.GET("/users/:id", func(c *gin.Context) {
		accountID, _ := c.Get("account_id")
		response, err := workload.ParseRouted(c.Param("id"), c.Query("verbose"), accountID.(int))
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_field"})
			return
		}
		c.JSON(http.StatusOK, response)
	})

	address := ":8081"
	if len(os.Args) > 1 {
		address = ":" + os.Args[1]
	}
	if err := http.ListenAndServe(address, router); err != nil {
		panic(err)
	}
}

func readBody(c *gin.Context) []byte {
	data, err := c.GetRawData()
	if err != nil {
		panic(fmt.Errorf("read request body: %w", err))
	}
	return data
}
