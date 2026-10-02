-- База и роль для Gitea; Artifactory использует POSTGRES_DB/POSTGRES_USER
-- из переменных окружения сервиса postgres.
CREATE ROLE gitea WITH LOGIN PASSWORD 'gitea';
CREATE DATABASE gitea OWNER gitea;
\connect gitea
CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION gitea;
