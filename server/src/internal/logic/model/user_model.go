package model

type UserModel struct {
	Id int	`json:"id"`
	UserId uint64 `json:"user_id"`
	UserNickName string `json:"user_nick_name"`
	UserToken string `json:"user_token"`
	UserAttach string `json:"user_attach"`
	Created int	`json:"created"`
	Updated int `json:"updated"`
}