wget -O nexus3.0.sh https://raw.githubusercontent.com/acxcr/nexus3.0/main/nexus3.0.sh && sed -i 's/\r//' nexus3.0.sh && chmod +x nexus3.0.sh && ./nexus3.0.sh


Nexus Pro 节点管理脚本（多组多ID无轮换版）说明
1. 脚本功能
一键批量部署/管理多组Nexus节点（每组支持自定义代理与多个ID，但仅首ID参与启动，无轮换）

支持手动编辑配置文件、增删组/ID、日志查看、配置备份恢复

支持运维菜单“一键补齐启动新组”

2. 使用方法
① 依赖环境
Linux 系统（建议 Ubuntu 20+）

需要 root 权限

安装 docker、jq、nano、curl（首次执行脚本会自动检测/提示安装）

② 启动方式
bash
复制
编辑
bash nexus3.0.sh
③ 常用菜单说明
1. 创建新的实例组
批量创建新组并自动启动

2. 实例组控制中心
查看、重启、停止、看日志（支持组编号选择）

3. 停止/重启所有ID
一键操作全部正在运行实例

4. 配置管理
手动编辑json配置、备份与恢复

5. 完全卸载
删除所有相关容器、镜像、配置、缓存

6. 退出

7. 补齐启动所有未运行实例组
适合手动编辑/导入配置文件后补齐新组实例

④ 配置文件说明（nexus-master-config.json）
每组格式如下：

json
复制
编辑
"nexus-group-3": {
  "proxy_address": "socks5://user:pass@ip:port",
  "id_pool": ["你的ID"]
}
说明：

组名可递增，例如 nexus-group-3、nexus-group-4……

proxy_address 可用 socks5:// 或 "no_proxy"

id_pool 支持多个ID，但仅首个ID生效

⑤ 增删组/ID方法
新增组/ID：编辑配置文件，保存后用菜单 7 “补齐启动”

删除组/ID：编辑配置文件，保存后用菜单 3 “停止/重启所有ID” 或 7 “补齐启动”

不会自动轮换ID，所有容器仅用各自的首ID启动

⑥ 日志与数据
日志文件在 logs 目录，按组编号命名

支持 tail 实时查看

3. 友情提示
编辑配置文件后，务必用菜单7“补齐启动”以启动新增组

推荐定期备份配置文件

如需批量导入ID和代理，请自行编辑批量脚本或联系脚本作者

