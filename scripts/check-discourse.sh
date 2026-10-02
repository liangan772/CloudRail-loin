#!/usr/bin/env bash
# 一键诊断 Discourse 容器启动状态
# 用法：bash check-discourse.sh
#
# 注意：本脚本的输出可能包含敏感信息（数据库、SMTP 等），
#       贴到公开渠道前请自行脱敏。脚本本身不会打印 env 变量。
set -uo pipefail

echo "==================== 1. 容器状态 ===================="
docker ps -a --filter "name=^app$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo

echo "==================== 2. 磁盘空间（migrate 失败的常见原因）===================="
df -h / /var/lib/docker /data 2>/dev/null | sort -u
echo

echo "==================== 3. 容器内启动日志末尾 60 行 ===================="
docker logs app --tail 60 2>&1
echo

echo "==================== 4. 关键错误检索 ===================="
echo "--- db:migrate 相关 ---"
docker logs app 2>&1 | grep -n -i "migrate" | tail -20
echo
echo "--- Ruby 异常 / 常量错误 / 数据库错误 ---"
docker logs app 2>&1 \
  | grep -n -E "NameError|uninitialized constant|NoMethodError|PG::|ActiveRecord|Zeitwerk|LOAD_PATH" \
  | tail -30
echo
echo "--- 是否已成功启动 ---"
docker logs app 2>&1 | grep -n -E "Starting Unicorn|master process ready|worker=0 ready|Listening" | tail -10
echo

echo "==================== 5. HTTP 健康检查 ===================="
curl -sS -o /dev/null -w "本地 8040 -> HTTP %{http_code}\n" --max-time 10 http://localhost:8040/ 2>&1
curl -sS -o /dev/null -w "站点首页 -> HTTP %{http_code}\n" --max-time 10 https://www.crbbsx.com/ 2>&1
echo

echo "==================== 6. 已安装的插件 ===================="
ls -1 /data/discourse/shared/standalone/plugins 2>/dev/null || echo "（该路径不存在，插件可能在 app.yml 的 hooks 里 clone）"
echo
ls -1 /var/discourse/plugins 2>/dev/null || true
echo

echo "==================== 7. app.yml 中插件相关配置 ===================="
grep -n -A 12 "after_code" /var/discourse/containers/app.yml 2>/dev/null || echo "（读不到 app.yml，请确认路径）"
echo

echo "诊断完成。请把上面【第 4 节】和【第 3 节】的输出发给我。"
