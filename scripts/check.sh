#!/bin/bash
set -e


PROJECT_NAME="test_project_$(date +%s)"
BACKUP_FILE="backup_$(date +%s).tar.gz"
PORT=8080


cleanup() {
  echo "Очистка тестовых ресурсов..."
  docker compose -p $PROJECT_NAME down -v || true
  rm -f $BACKUP_FILE || true
}
trap cleanup EXIT

echo "=== Этап 1: Запуск тестового проекта ==="
docker compose -p $PROJECT_NAME up -d --build

echo "=== Этап 2: Ожидание готовности приложения ==="
for i in {1..30}; do
  if curl -s -f --max-time 2 http://localhost:$PORT/healthz > /dev/null; then
    echo "Приложение готово."
    break
  fi
  if [ $i -eq 30 ]; then
    echo "ОШИБКА: Приложение не стало готовым за 30 секунд."
    exit 1
  fi
  sleep 1
done

echo "=== Этап 3: Проверка исходного счётчика (должен быть 0) ==="
INITIAL=$(curl -s --max-time 5 http://localhost:$PORT/ | grep -o '"count": [0-9]*' | cut -d' ' -f2)
if [ "$INITIAL" != "0" ]; then
  echo "ОШИБКА: Исходный счётчик не 0, а $INITIAL"
  exit 1
fi
echo "Исходный счётчик: $INITIAL"

echo "=== Этап 4: Выполнение 5 инкрементов ==="
for i in {1..5}; do
  curl -s --max-time 5 -X POST http://localhost:$PORT/increment > /dev/null
done

AFTER=$(curl -s --max-time 5 http://localhost:$PORT/ | grep -o '"count": [0-9]*' | cut -d' ' -f2)
if [ "$AFTER" != "5" ]; then
  echo "ОШИБКА: После 5 инкрементов счётчик не 5, а $AFTER"
  exit 1
fi
echo "Счётчик после инкрементов: $AFTER"

echo "=== Этап 5: Пересоздание контейнера приложения ==="
docker compose -p $PROJECT_NAME up -d --force-recreate app
sleep 3
AFTER_RESTART=$(curl -s --max-time 5 http://localhost:$PORT/ | grep -o '"count": [0-9]*' | cut -d' ' -f2)
if [ "$AFTER_RESTART" != "5" ]; then
  echo "ОШИБКА: После пересоздания счётчик не 5, а $AFTER_RESTART"
  exit 1
fi
echo "Счётчик после пересоздания: $AFTER_RESTART"

echo "=== Этап 6: Проверка отказа Redis ==="
docker compose -p $PROJECT_NAME stop redis
sleep 2

READY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:$PORT/readyz)
if [ "$READY_CODE" != "503" ]; then
  echo "ОШИБКА: /readyz вернул $READY_CODE, ожидался 503"
  exit 1
fi
echo "/readyz вернул 503 (ожидаемо)"

INC_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST http://localhost:$PORT/increment)
if [ "$INC_CODE" != "503" ]; then
  echo "ОШИБКА: /increment вернул $INC_CODE, ожидался 503"
  exit 1
fi
echo "/increment вернул 503 (ожидаемо)"

echo "=== Этап 7: Восстановление Redis ==="
docker compose -p $PROJECT_NAME start redis
sleep 5
AFTER_RECOVERY=$(curl -s --max-time 5 http://localhost:$PORT/ | grep -o '"count": [0-9]*' | cut -d' ' -f2)
if [ "$AFTER_RECOVERY" != "5" ]; then
  echo "ОШИБКА: После восстановления Redis счётчик не 5, а $AFTER_RECOVERY"
  exit 1
fi
echo "Счётчик после восстановления: $AFTER_RECOVERY"

echo "=== Этап 8: Создание резервной копии ==="
docker compose -p $PROJECT_NAME stop app redis
BACKUP_CONTAINER="backup_$(date +%s)"
docker run --name $BACKUP_CONTAINER -v ${PROJECT_NAME}_redis-data:/data alpine cp -r /data /tmp/backup_data
docker cp $BACKUP_CONTAINER:/tmp/backup_data ./$BACKUP_FILE
docker rm $BACKUP_CONTAINER
echo "Резервная копия создана: $BACKUP_FILE"

echo "=== Все проверки пройдены успешно! ==="