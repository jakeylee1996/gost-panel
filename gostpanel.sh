#!/bin/bash

set -e

APP_DIR=~/gost-manager
GOST_VERSION="v3.1.0-nightly.20250702"
GOST_FILENAME="gost_3.1.0-nightly.20250702_linux_amd64.tar.gz"
GOST_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/${GOST_FILENAME}"
DOCKER_IMAGE_NAME="gost-manager"
DOCKER_CONTAINER_NAME="gost-panel"
PANEL_PORT=10055
USERNAME="admin"
PASSWORD="123456"

echo "[1] 安装依赖..."
sudo apt update && sudo apt install -y unzip docker.io wget

echo "[2] 准备工作目录：$APP_DIR"
mkdir -p $APP_DIR/templates
cd $APP_DIR

echo "[3] 下载 GOST..."
if [ ! -f gost ]; then
  wget -c $GOST_URL
  tar -xzf $GOST_FILENAME
  chmod +x gost
  rm $GOST_FILENAME
else
  echo "gost 已存在，跳过下载"
fi

echo "[4] 创建默认账号密码文件（如未存在）..."
if [ ! -f .credentials ]; then
  echo -e "${USERNAME}\n${PASSWORD}" > .credentials
fi

echo "[5] 写入 app.py..."
cat > app.py <<'EOF'
from flask import Flask, request, render_template, redirect, url_for
import os
from gost_process import tunnels, add_tunnel, remove_tunnel

app = Flask(__name__)
CRED_FILE = '.credentials'

def load_credentials():
    if os.path.exists(CRED_FILE):
        with open(CRED_FILE) as f:
            lines = f.read().splitlines()
            if len(lines) >= 2:
                return lines[0], lines[1]
    return os.getenv('PANEL_USERNAME', 'admin'), os.getenv('PANEL_PASSWORD', '123456')

username, password = load_credentials()

@app.before_request
def basic_auth():
    global username, password
    auth = request.authorization
    if not auth or not (auth.username == username and auth.password == password):
        return "Unauthorized", 401, {'WWW-Authenticate': 'Basic realm=\"Login Required\"'}

@app.route('/')
def index():
    return render_template('index.html', tunnels=tunnels)

@app.route('/add', methods=['POST'])
def add():
    name = request.form['name']
    local_port = request.form['local_port']
    remote_host = request.form['remote_host']
    remote_port = request.form['remote_port']
    add_tunnel(name, local_port, remote_host, remote_port)
    return redirect(url_for('index'))

@app.route('/delete/<name>', methods=['POST'])
def delete(name):
    remove_tunnel(name)
    return redirect(url_for('index'))

@app.route('/change_credentials', methods=['GET', 'POST'])
def change_credentials():
    global username, password
    if request.method == 'POST':
        new_user = request.form['username'].strip()
        new_pass = request.form['password'].strip()
        if not new_user or not new_pass:
            return "用户名和密码不能为空", 400
        with open(CRED_FILE, 'w') as f:
            f.write(f'{new_user}\n{new_pass}\n')
        username, password = new_user, new_pass
        return redirect(url_for('index'))
    return '''
        <h2>修改账号密码</h2>
        <form method="post">
            <label>新用户名: <input name="username" required></label><br><br>
            <label>新密码: <input name="password" type="password" required></label><br><br>
            <button type="submit">保存</button>
        </form>
        <br>
        <a href="/">返回主页</a>
    '''

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv("PANEL_PORT", "10055")))
EOF

echo "[6] 写入 gost_process.py..."
cat > gost_process.py <<'EOF'
import subprocess
import time

tunnels = {}

def add_tunnel(name, local_port, remote_host, remote_port):
    cmd = [
        "./gost",
        f"-L=tcp://:{local_port}",
        f"-F=tcp://{remote_host}:{remote_port}"
    ]
    print("启动命令：", " ".join(cmd))
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        time.sleep(1)
        if proc.poll() is not None:
            stdout, stderr = proc.communicate()
            print("启动失败")
            print("stderr:", stderr.decode())
            return
        tunnels[name] = {
            "process": proc,
            "local_port": local_port,
            "remote_host": remote_host,
            "remote_port": remote_port
        }
        print(f"隧道 {name} 启动成功")
    except Exception as e:
        print("错误：", str(e))

def remove_tunnel(name):
    if name in tunnels:
        print(f"[DEL] 正在删除隧道 {name}")
        tunnels[name]["process"].terminate()
        tunnels[name]["process"].wait()
        del tunnels[name]
EOF

echo "[7] 写入 index.html..."
cat > templates/index.html <<EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <title>GOST 隧道管理</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
<div class="container py-5">
    <div class="mb-4 text-end">
        <a href="/change_credentials" class="btn btn-warning">修改账号密码</a>
    </div>

    <div class="card shadow-sm mb-4">
        <div class="card-header bg-primary text-white">
            <h3 class="mb-0">GOST 隧道列表</h3>
        </div>
        <div class="card-body">
            {% if tunnels %}
            <ul class="list-group">
                {% for name, info in tunnels.items() %}
                <li class="list-group-item">
                    <div class="d-flex justify-content-between align-items-center">
                        <div>
                            <h5 class="mb-1">{{ name }}</h5>
                            <p class="mb-0 text-muted">
                                本地监听：<code>0.0.0.0:{{ info.local_port }}</code><br>
                                转发目标：<code>{{ info.remote_host }}:{{ info.remote_port }}</code>
                            </p>
                        </div>
                        <form action="{{ url_for('delete', name=name) }}" method="post" class="m-0">
                            <button type="submit" class="btn btn-danger btn-sm">删除</button>
                        </form>
                    </div>
                </li>
                {% endfor %}
            </ul>
            {% else %}
            <p class="text-muted">暂无隧道。</p>
            {% endif %}
        </div>
    </div>

    <div class="card shadow-sm">
        <div class="card-header bg-success text-white">
            <h3 class="mb-0">新增隧道</h3>
        </div>
        <div class="card-body">
            <form action="/add" method="post">
                <div class="mb-3">
                    <label class="form-label">名称</label>
                    <input name="name" class="form-control" required>
                </div>
                <div class="mb-3">
                    <label class="form-label">本地端口</label>
                    <input name="local_port" class="form-control" required pattern="\\d+">
                </div>
                <div class="mb-3">
                    <label class="form-label">远程地址</label>
                    <input name="remote_host" class="form-control" required>
                </div>
                <div class="mb-3">
                    <label class="form-label">远程端口</label>
                    <input name="remote_port" class="form-control" required pattern="\\d+">
                </div>
                <button type="submit" class="btn btn-success">添加</button>
            </form>
        </div>
    </div>
</div>
</body>
</html>
EOF

echo "[8] 写入 Dockerfile..."
cat > Dockerfile <<EOF
FROM python:3.11-slim
WORKDIR /app
COPY . /app
RUN apt update && apt install -y telnet net-tools iputils-ping
RUN pip install flask
RUN chmod +x ./gost
EXPOSE ${PANEL_PORT}
CMD ["python", "app.py"]
EOF

echo "[9] 移除旧容器（如存在）..."
docker rm -f $DOCKER_CONTAINER_NAME 2>/dev/null || true

echo "[10] 构建 Docker 镜像..."
docker build -t $DOCKER_IMAGE_NAME .

echo "[11] 启动 Docker 容器（host 网络模式）..."
docker run -d \
  --network=host \
  --name ${DOCKER_CONTAINER_NAME} \
  $DOCKER_IMAGE_NAME

echo ""
echo "部署完成！"
echo "管理地址： http://$(hostname -I | awk '{print $1}'):${PANEL_PORT}"
echo "用户名：$USERNAME"
echo "密码：$PASSWORD"
