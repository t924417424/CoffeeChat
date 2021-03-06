package rpcserver

import (
	"context"
	"github.com/BurntSushi/toml"
	"github.com/CoffeeChat/server/src/api/cim"
	"github.com/CoffeeChat/server/src/internal/logic/conf"
	"github.com/CoffeeChat/server/src/pkg/db"
	"github.com/CoffeeChat/server/src/pkg/logger"
	"google.golang.org/grpc"
	"testing"
	"time"
)

func TestLogicServer_RecentContactSession(t *testing.T) {
	logger.InitLogger("../../../log/log.log", "debug")
	_, err := toml.DecodeFile("../../../app/logic/logic-example.toml", conf.DefaultLogicConfig)
	if err != nil {
		t.Fatal(err.Error())
	}

	// init db
	err = db.DefaultManager.Init(conf.DefaultLogicConfig.Db)
	if err != nil {
		t.Fatal(err.Error())
	}

	// init cache
	redis := conf.DefaultLogicConfig.Redis
	err = db.InitCache(redis.Ip, redis.Port, redis.Password, redis.KeyPrefix, redis.Pool)
	if err != nil {
		t.Fatal(err.Error())
	}

	go StartRpcServer("127.0.0.1", 10600)

	conn, err := grpc.Dial("127.0.0.1:10600", grpc.WithInsecure())
	if err != nil {
		t.Error(err)
	}

	clientConn := cim.NewLogicClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second*3)
	defer cancel()

	res, err := clientConn.RecentContactSession(ctx, &cim.CIMRecentContactSessionReq{
		UserId:           1008,
		LatestUpdateTime: 0,
	})

	if err != nil {
		t.Error(err)
	}

	logger.Sugar.Info("recent_session res:", res.String())
}

func TestLogicServer_GetMsgList(t *testing.T) {
	logger.InitLogger("../../../log/log.log", "debug")
	_, err := toml.DecodeFile("../../../app/logic/logic-example.toml", conf.DefaultLogicConfig)
	if err != nil {
		t.Fatal(err.Error())
	}

	// init db
	err = db.DefaultManager.Init(conf.DefaultLogicConfig.Db)
	if err != nil {
		t.Fatal(err.Error())
	}

	// init cache
	redis := conf.DefaultLogicConfig.Redis
	err = db.InitCache(redis.Ip, redis.Port, redis.Password, redis.KeyPrefix, redis.Pool)
	if err != nil {
		t.Fatal(err.Error())
	}

	go StartRpcServer("127.0.0.1", 10600)

	conn, err := grpc.Dial("127.0.0.1:10600", grpc.WithInsecure())
	if err != nil {
		t.Error(err)
	}

	clientConn := cim.NewLogicClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second*3)
	defer cancel()

	res, err := clientConn.GetMsgList(ctx, &cim.CIMGetMsgListReq{
		UserId:      1008,
		SessionId:   1009, // 单聊用户，查询我和1009的会话下的聊天记录
		SessionType: cim.CIMSessionType_kCIM_SESSION_TYPE_SINGLE,
		LimitCount:  2,
		EndMsgId:    4,
	})

	if err != nil {
		t.Error(err)
	}

	logger.Sugar.Info("send msg res:", res.String())
	for i := range res.MsgList {
		item := res.MsgList[i]
		logger.Sugar.Infof("%d->%d:%s", item.FromUserId, item.ToSessionId, string(item.MsgData))
	}
}
