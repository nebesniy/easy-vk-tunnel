#!/bin/bash

# Конфигурация
UUID="12345678-1234-1234-1234-123456789abc"
INBOUNDPORT="8080"
WSPATH="/"

# функция для URL encoding
urlencode() {
	local string="$1"
	local length="${#string}"
	local encoded=""
	local i char

	for ((i = 0; i < length; i++)); do
		char="${string:i:1}"
		case "$char" in
			[a-zA-Z0-9.~_-]) encoded+="$char" ;;
			*) encoded+=$(printf '%%%02X' "'$char") ;;
		esac
	done
	echo "$encoded"
}

# проверка конфигурации
if [[ -z "$UUID" || -z "$INBOUNDPORT" || -z "$WSPATH" ]]; then
	echo "Ошибка: Не все конфигурационные переменные заполнены!"
	echo "Отредактируйте скрипт и заполните UUID, порт инбаунда и директорию веб-сокетов (Path)"
	exit 1
fi

echo "=== Ваша конфигурация ==="
echo "UUID: $UUID"
echo "INBOUNDPORT: $INBOUNDPORT"
echo "WSPATH: $WSPATH"
echo ""

# проверяем, установлен ли vk-tunnel
if ! command -v vk-tunnel &> /dev/null; then
	echo "Ошибка: vk-tunnel не установлен или не найден в PATH"
	exit 1
fi

# убиваем существующий процесс vk-tunnel
echo "Проверка запущенных процессов vk-tunnel..."
VK_PID=$(pgrep -f "vk-tunnel --port=$INBOUNDPORT")

if [ ! -z "$VK_PID" ]; then
	echo "Найден запущенный vk-tunnel (PID: $VK_PID). Останавливаем..."
	kill $VK_PID
	sleep 2
	
	# проверяем, что процесс убит
	if ps -p $VK_PID > /dev/null 2>&1; then
		echo "Принудительное завершение процесса..."
		kill -9 $VK_PID
	fi
	echo "Процесс vk-tunnel остановлен."
fi

# запускаем vk-tunnel в фоне
echo "Запуск vk-tunnel на порту $INBOUNDPORT..."
vk-tunnel --port=$INBOUNDPORT > /tmp/vk-tunnel.log 2>&1 &

# время для запуска vk-tunnel
sleep 5

# проверяем, что процесс запустился
VK_PID=$(pgrep -f "vk-tunnel --port=$INBOUNDPORT")
if [ -z "$VK_PID" ]; then
	echo "Ошибка: vk-tunnel не запустился. Проверьте логи в /tmp/vk-tunnel.log"
	exit 1
fi

echo "vk-tunnel успешно запущен (PID: $VK_PID)"

# извлекаем домен из логов
echo "Извлечение домена из вывода vk-tunnel..."
DOMAIN=$(grep -oE '[a-zA-Z0-9-]+-yp[0-9a-zA-Z]+\.tunnel\.vk-apps\.com' /tmp/vk-tunnel.log | tail -n1)

if [ -z "$DOMAIN" ]; then
	echo "Ошибка: Не удалось извлечь домен из вывода vk-tunnel"
	echo "Содержимое лога:"
	cat /tmp/vk-tunnel.log
	exit 1
fi

echo "Найден домен: $DOMAIN"

# URL encode для WSPATH
ENCODED_WSPATH=$(urlencode "$WSPATH")

# формируем vless ссылку
VLESS_LINK="vless://${UUID}@${DOMAIN}:443/?type=ws&path=${ENCODED_WSPATH}&security=tls#vk-tunnel"

echo ""
echo "=== Ссылка успешно сгенерирована ==="
echo "$VLESS_LINK"
echo ""
echo "=== QR код ==="

# пытаемся показать QR код если установлен qrencode
if command -v qrencode &> /dev/null; then
	qrencode -t UTF8 "$VLESS_LINK"
else
	echo "Для отображения QR кода установите: sudo apt-get install qrencode"
fi

echo ""
echo "Логи vk-tunnel: /tmp/vk-tunnel.log"
echo "Для остановки выполните: kill $VK_PID"
echo ""
echo "Для изменения конфигурации отредактируйте переменные в начале скрипта"
