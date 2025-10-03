#!/bin/bash

# ===============================================
# Script de Setup - Stack de Dados para Portf贸lio
# ===============================================

echo "Criando Stack de Dados para Portfolio..."
echo ""

# Criar diretorio do projeto
mkdir -p data-stack-portfolio
cd data-stack-portfolio

# Criar estrutura de direterios
echo "Criando estrutura de direterios..."
mkdir -p dagster_home/{storage,logs}
mkdir -p pipelines
mkdir -p scripts
mkdir -p data/{raw,processed,duckdb}
mkdir -p dbt_project/{models,seeds,macros,tests}

# Criar arquivo .env
echo " Criando arquivo .env..."
cat > .env << 'EOF'
# PostgreSQL Configuration
POSTGRES_USER=datauser
POSTGRES_PASSWORD=datapass123
POSTGRES_HOST=host.docker.internal
POSTGRES_PORT=5432

# MinIO Configuration
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin123
EOF

# Criar docker-compose.yml
echo " Criando docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # ============================================
  # DATA LAKE - MinIO
  # ============================================
  
  minio:
    image: minio/minio:latest
    container_name: portfolio_minio
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin123
      MINIO_BROWSER_REDIRECT_URL: http://localhost:9001
    volumes:
      - minio_data:/data
    ports:
      - "9000:9000"
      - "9001:9001"
    command: server /data --console-address ":9001"
    mem_limit: 512m
    cpus: 0.5
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - data_network
    restart: unless-stopped

  minio-setup:
    image: minio/mc:latest
    container_name: portfolio_minio_setup
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      sleep 5;
      /usr/bin/mc alias set myminio http://minio:9000 minioadmin minioadmin123;
      /usr/bin/mc mb myminio/raw --ignore-existing;
      /usr/bin/mc mb myminio/processed --ignore-existing;
      /usr/bin/mc mb myminio/landing --ignore-existing;
      echo '鉁?MinIO configurado!';
      exit 0;
      "
    networks:
      - data_network

  # ============================================
  # INGEST脙O - Airbyte
  # ============================================
  
  airbyte-server:
    image: airbyte/server:0.50.0
    container_name: portfolio_airbyte_server
    environment:
      DATABASE_USER: ${POSTGRES_USER:-datauser}
      DATABASE_PASSWORD: ${POSTGRES_PASSWORD:-datapass123}
      DATABASE_HOST: ${POSTGRES_HOST:-host.docker.internal}
      DATABASE_PORT: ${POSTGRES_PORT:-5432}
      DATABASE_DB: airbyte
      CONFIG_ROOT: /data
      WORKSPACE_ROOT: /tmp/workspace
    volumes:
      - airbyte_data:/data
      - airbyte_workspace:/tmp/workspace
    ports:
      - "8001:8001"
    mem_limit: 1g
    cpus: 1.0
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  airbyte-webapp:
    image: airbyte/webapp:0.50.0
    container_name: portfolio_airbyte_webapp
    environment:
      AIRBYTE_SERVER_HOST: airbyte-server
      AIRBYTE_SERVER_PORT: 8001
    ports:
      - "8000:80"
    mem_limit: 512m
    cpus: 0.5
    depends_on:
      - airbyte-server
    networks:
      - data_network
    restart: unless-stopped

  airbyte-worker:
    image: airbyte/worker:0.50.0
    container_name: portfolio_airbyte_worker
    environment:
      DATABASE_USER: ${POSTGRES_USER:-datauser}
      DATABASE_PASSWORD: ${POSTGRES_PASSWORD:-datapass123}
      DATABASE_HOST: ${POSTGRES_HOST:-host.docker.internal}
      DATABASE_PORT: ${POSTGRES_PORT:-5432}
      DATABASE_DB: airbyte
      CONFIG_ROOT: /data
      WORKSPACE_ROOT: /tmp/workspace
      LOCAL_ROOT: /tmp/airbyte_local
      AIRBYTE_SERVER_HOST: airbyte-server
      AIRBYTE_SERVER_PORT: 8001
    volumes:
      - airbyte_workspace:/tmp/workspace
      - airbyte_local:/tmp/airbyte_local
      - /var/run/docker.sock:/var/run/docker.sock
    mem_limit: 1g
    cpus: 1.0
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  airbyte-temporal:
    image: temporalio/auto-setup:1.20.0
    container_name: portfolio_airbyte_temporal
    environment:
      DB: postgresql
      DB_PORT: ${POSTGRES_PORT:-5432}
      POSTGRES_USER: ${POSTGRES_USER:-datauser}
      POSTGRES_PWD: ${POSTGRES_PASSWORD:-datapass123}
      POSTGRES_SEEDS: ${POSTGRES_HOST:-host.docker.internal}
      DYNAMIC_CONFIG_FILE_PATH: config/dynamicconfig/development.yaml
    mem_limit: 512m
    cpus: 0.5
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  # ============================================
  # ORQUESTRACAO - Dagster
  # ============================================
  
  dagster:
    image: dagster/dagster:1.5.0
    container_name: portfolio_dagster
    environment:
      DAGSTER_POSTGRES_USER: ${POSTGRES_USER:-datauser}
      DAGSTER_POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-datapass123}
      DAGSTER_POSTGRES_DB: dagster
      DAGSTER_POSTGRES_HOSTNAME: ${POSTGRES_HOST:-host.docker.internal}
      DAGSTER_POSTGRES_PORT: ${POSTGRES_PORT:-5432}
      AWS_ACCESS_KEY_ID: minioadmin
      AWS_SECRET_ACCESS_KEY: minioadmin123
      AWS_ENDPOINT_URL: http://minio:9000
    volumes:
      - ./dagster_home:/opt/dagster/dagster_home
      - ./pipelines:/opt/dagster/pipelines
      - ./data:/opt/dagster/data
    ports:
      - "3000:3000"
    mem_limit: 1g
    cpus: 1.0
    depends_on:
      minio:
        condition: service_healthy
    command: dagster-webserver -h 0.0.0.0 -p 3000
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  dagster-daemon:
    image: dagster/dagster:1.5.0
    container_name: portfolio_dagster_daemon
    environment:
      DAGSTER_POSTGRES_USER: ${POSTGRES_USER:-datauser}
      DAGSTER_POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-datapass123}
      DAGSTER_POSTGRES_DB: dagster
      DAGSTER_POSTGRES_HOSTNAME: ${POSTGRES_HOST:-host.docker.internal}
      DAGSTER_POSTGRES_PORT: ${POSTGRES_PORT:-5432}
    volumes:
      - ./dagster_home:/opt/dagster/dagster_home
      - ./pipelines:/opt/dagster/pipelines
    mem_limit: 512m
    cpus: 0.5
    command: dagster-daemon run
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  # ============================================
  # BI - Metabase
  # ============================================
  
  metabase:
    image: metabase/metabase:v0.48.0
    container_name: portfolio_metabase
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_PORT: ${POSTGRES_PORT:-5432}
      MB_DB_USER: ${POSTGRES_USER:-datauser}
      MB_DB_PASS: ${POSTGRES_PASSWORD:-datapass123}
      MB_DB_HOST: ${POSTGRES_HOST:-host.docker.internal}
      JAVA_OPTS: "-Xmx1g"
    volumes:
      - metabase_data:/metabase-data
    ports:
      - "3001:3000"
    mem_limit: 1.5g
    cpus: 1.0
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    restart: unless-stopped

  # ============================================
  # MONITORAMENTO (Opcional)
  # ============================================
  
  grafana:
    image: grafana/grafana:10.2.0
    container_name: portfolio_grafana
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3002:3000"
    mem_limit: 256m
    cpus: 0.5
    networks:
      - data_network
    restart: unless-stopped
    profiles:
      - monitoring

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.0
    container_name: portfolio_cadvisor
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports:
      - "8080:8080"
    mem_limit: 128m
    cpus: 0.25
    networks:
      - data_network
    restart: unless-stopped
    profiles:
      - monitoring

  # ============================================
  # UTILITARIOS
  # ============================================
  
  dbt:
    image: ghcr.io/dbt-labs/dbt-postgres:1.7.0
    container_name: portfolio_dbt
    volumes:
      - ./dbt_project:/usr/app
      - ./data:/data
    working_dir: /usr/app
    mem_limit: 512m
    cpus: 0.5
    command: tail -f /dev/null
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    profiles:
      - tools

  python-worker:
    image: python:3.11-slim
    container_name: portfolio_python
    environment:
      AWS_ACCESS_KEY_ID: minioadmin
      AWS_SECRET_ACCESS_KEY: minioadmin123
      AWS_ENDPOINT_URL: http://minio:9000
    volumes:
      - ./scripts:/scripts
      - ./data:/data
    working_dir: /scripts
    mem_limit: 512m
    cpus: 0.5
    command: >
      bash -c "
      pip install -q boto3 pandas duckdb pyarrow requests psycopg2-binary sqlalchemy &&
      tail -f /dev/null
      "
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - data_network
    profiles:
      - tools

volumes:
  minio_data:
  airbyte_data:
  airbyte_workspace:
  airbyte_local:
  metabase_data:
  grafana_data:

networks:
  data_network:
    driver: bridge
EOF

# Criar arquivo .gitignore
echo "Criando .gitignore..."
cat > .gitignore << 'EOF'
# Environment
.env
*.log

# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
venv/
env/

# Data
data/raw/*
data/processed/*
data/duckdb/*.duckdb*
!data/raw/.gitkeep
!data/processed/.gitkeep

# Dagster
dagster_home/storage/*
dagster_home/logs/*
!dagster_home/.gitkeep

# dbt
dbt_project/target/
dbt_project/dbt_packages/
dbt_project/logs/

# Docker volumes (se commitado localmente)
*_data/

# IDE
.vscode/
.idea/
*.swp
*.swo
EOF

# Criar configurao do Dagster
echo "Criando configuracao do Dagster..."
cat > dagster_home/dagster.yaml << 'EOF'
run_coordinator:
  module: dagster.core.run_coordinator
  class: DefaultRunCoordinator

run_launcher:
  module: dagster.core.launcher
  class: DefaultRunLauncher

compute_logs:
  module: dagster.core.storage.local_compute_log_manager
  class: LocalComputeLogManager
  config:
    base_dir: /opt/dagster/dagster_home/logs
EOF

# Criar exemplo de pipeline Dagster
echo "Criando pipeline de exemplo..."
cat > pipelines/example_pipeline.py << 'EOF'
"""
Pipeline de exemplo para o portf贸lio
"""
from dagster import asset, Definitions, ScheduleDefinition, define_asset_job
import pandas as pd
from datetime import datetime

@asset(description="Gera dados de exemplo")
def raw_data():
    """Cria dataset de exemplo"""
    data = {
        'id': range(1, 101),
        'produto': ['Produto_A', 'Produto_B', 'Produto_C'] * 33 + ['Produto_A'],
        'quantidade': [i % 10 + 1 for i in range(1, 101)],
        'valor': [19.99, 29.99, 39.99] * 33 + [19.99],
        'data': pd.date_range(start='2024-01-01', periods=100, freq='D')
    }
    df = pd.DataFrame(data)
    
    # Salvar localmente
    df.to_csv('/opt/dagster/data/raw/vendas.csv', index=False)
    
    return df

@asset(deps=[raw_data], description="Processa dados")
def processed_data():
    """Transforma dados brutos"""
    df = pd.read_csv('/opt/dagster/data/raw/vendas.csv')
    
    # Adicionar colunas calculadas
    df['valor_total'] = df['quantidade'] * df['valor']
    df['processed_at'] = datetime.now()
    
    # Salvar processado
    df.to_csv('/opt/dagster/data/processed/vendas_processado.csv', index=False)
    
    return df

@asset(deps=[processed_data], description="Métricas agregadas")
def metrics():
    """Calcula métricas de negocio"""
    df = pd.read_csv('/opt/dagster/data/processed/vendas_processado.csv')
    
    metrics = {
        'total_vendas': df['valor_total'].sum(),
        'qtd_pedidos': len(df),
        'ticket_medio': df['valor_total'].mean(),
        'produto_mais_vendido': df.groupby('produto')['quantidade'].sum().idxmax()
    }
    
    return metrics

# Definir job
pipeline_job = define_asset_job(
    name="pipeline_exemplo",
    selection=[raw_data, processed_data, metrics]
)

# Schedule diario
daily_schedule = ScheduleDefinition(
    job=pipeline_job,
    cron_schedule="0 2 * * *",  # 2h AM todo dia
)

# Exportar definicoes
defs = Definitions(
    assets=[raw_data, processed_data, metrics],
    jobs=[pipeline_job],
    schedules=[daily_schedule]
)
EOF

# Criar script Python de exemplo
echo "Criando script Python de exemplo..."
cat > scripts/test_minio.py << 'EOF'
"""
Script para testar conexão com MinIO
"""
import boto3
import os
from datetime import datetime

# Configurar cliente S3/MinIO
s3 = boto3.client(
    's3',
    endpoint_url=os.getenv('AWS_ENDPOINT_URL', 'http://minio:9000'),
    aws_access_key_id=os.getenv('AWS_ACCESS_KEY_ID', 'minioadmin'),
    aws_secret_access_key=os.getenv('AWS_SECRET_ACCESS_KEY', 'minioadmin123')
)

def test_connection():
    """Testa conex茫o com MinIO"""
    try:
        # Listar buckets
        response = s3.list_buckets()
        print("鉁?Conex茫o com MinIO OK!")
        print(f" Buckets: {[b['Name'] for b in response['Buckets']]}")
        
        # Upload teste
        test_content = f"Teste em {datetime.now()}"
        s3.put_object(
            Bucket='landing',
            Key='test.txt',
            Body=test_content.encode()
        )
        print("鉁?Upload de teste realizado!")
        
        return True
    except Exception as e:
        print(f"Erro: {e}")
        return False

if __name__ == "__main__":
    test_connection()
EOF

# Criar README
echo " Criando README.md..."
cat > README.md << 'EOF'
# Stack de Engenharia de Dados - Portf贸lio

Stack completa e moderna de Data Engineering com ferramentas open-source.

## Arquitetura

- **MinIO**: Data Lake (S3-compatible)
- **Airbyte**: Ingest茫o de dados (350+ conectores)
- **Dagster**: Orquestrao de pipelines
- **dbt**: Transformações SQL
- **Metabase**: Business Intelligence
- **PostgreSQL**: Metadados (externo)

## Como Usar

### 1. Preparar PostgreSQL

```sql
CREATE DATABASE airbyte;
CREATE DATABASE dagster;
CREATE DATABASE metabase;
CREATE DATABASE analytics;

CREATE USER datauser WITH PASSWORD 'datapass123';
GRANT ALL PRIVILEGES ON DATABASE airbyte TO datauser;
GRANT ALL PRIVILEGES ON DATABASE dagster TO datauser;
GRANT ALL PRIVILEGES ON DATABASE metabase TO datauser;
GRANT ALL PRIVILEGES ON DATABASE analytics TO datauser;
```

### 2. Ajustar .env

Edite o arquivo `.env` com suas credenciais do PostgreSQL.

### 3. Subir Stack

```bash
# Serviços principais
docker-compose up -d

# Ver logs
docker-compose logs -f

# Parar tudo
docker-compose down
```

### 4. Acessar Interfaces

- **Airbyte**: http://localhost:8000
- **Dagster**: http://localhost:3000
- **Metabase**: http://localhost:3001
- **MinIO**: http://localhost:9001

## Recursos

- RAM: ~5.5GB
- CPU: 3.5 cores
- Disco: ~10GB

## Comandos úteis

```bash
# Subir com ferramentas adicionais
docker-compose --profile tools up -d

# Subir com monitoramento
docker-compose --profile monitoring up -d

# Executar pipeline Dagster
docker-compose exec dagster dagster job execute -f /opt/dagster/pipelines/example_pipeline.py

# Testar MinIO
docker-compose exec python-worker python /scripts/test_minio.py

# Ver status
docker-compose ps
```




## Licença

MIT
EOF

# Criar arquivos .gitkeep
touch data/raw/.gitkeep
touch data/processed/.gitkeep
touch dagster_home/.gitkeep

echo ""
echo "Setup completo!"
echo ""
echo "Próximos passos:"
echo ""
echo "1. Ajustar credenciais PostgreSQL no arquivo .env"
echo "2. Subir a stack: docker-compose up -d"
echo "3. Aguardar ~2 minutos para inicializao"
echo "4. Acessar interfaces:"
echo "   - Airbyte: http://localhost:8000"
echo "   - Dagster: http://localhost:3000"
echo "   - Metabase: http://localhost:3001"
echo "   - MinIO: http://localhost:9001"
echo ""
echo "Leia o README.md para mais informações"
echo ""
echo "Bom trabalho com seu portfólio!"
EOF

chmod +x create-stack.sh
echo ""
echo "Script criado com sucesso!"
echo ""
echo "Execute agora:"
echo "  bash create-stack.sh"
