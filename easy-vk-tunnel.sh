#!/bin/bash

# Easy VK Tunnel v2.0

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# конфиг файл
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/settings.conf"
LOG_FILE="/tmp/easy-vk-tunnel.log"

VK_TUNNEL_CMD="/usr/local/bin/vk-tunnel" 
AWS_CMD="/usr/bin/aws"
CURL_CMD="/usr/bin/curl"
PGREP_CMD="/usr/bin/pgrep"
PKILL_CMD="/usr/bin/pkill"

# логи
log() {
	echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
	echo "$1"
}

# читаем конфиг
read_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		source "$CONFIG_FILE"
	else
		log "Конфигурационный файл не найден: $CONFIG_FILE"
		return 1
	fi
}

# пишем конфиг
write_config() {
	cat > "$CONFIG_FILE" << EOF
UUID="$UUID"
INBOUNDPORT="$INBOUNDPORT"
WSPATH="$WSPATH"
SUBSCRIPTION_FILE="$SUBSCRIPTION_FILE"
BUCKET_NAME="$BUCKET_NAME"
SA_ACCESS_KEY_ID="$SA_ACCESS_KEY_ID"
SA_SECRET_ACCESS_KEY="$SA_SECRET_ACCESS_KEY"
LAST_DOMAIN="$LAST_DOMAIN"
EOF
	chmod 600 "$CONFIG_FILE"
}

# urlencode
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

# установка компонентов
install_dependencies() {
	log "Установка зависимостей..."
	
	apt-get update
	apt-get install -y curl cron unzip
	
	# Скачивание и установка AWS CLI v2
	cd /tmp
	curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
	unzip awscliv2.zip
	./aws/install
	
	# Очистка
	rm -rf awscliv2.zip aws/
	
	# Проверяем установку
	if command -v aws &> /dev/null; then
		log "AWS CLI v2 успешно установлен"
	else
		log "Ошибка: AWS CLI не установлен"
		return 1
	fi
}

# проверка наличия необходимых команд
check_commands() {
	local commands=("curl" "aws" "pgrep" "pkill")
	local missing=()
	
	for cmd in "${commands[@]}"; do
		if ! command -v "$cmd" &> /dev/null; then
			missing+=("$cmd")
		fi
	done
	
	if [[ ${#missing[@]} -gt 0 ]]; then
		log "Отсутствуют команды: ${missing[*]}"
		return 1
	fi
	
	return 0
}

# настройка awscli для s3 яндекса
configure_aws() {
	log "Настройка AWS CLI для Yandex.Cloud..."
	mkdir -p ~/.aws
	
	cat > ~/.aws/config << EOF
[default]
region=ru-central1
output=json
EOF

	cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id=$SA_ACCESS_KEY_ID
aws_secret_access_key=$SA_SECRET_ACCESS_KEY
EOF

	chmod 600 ~/.aws/credentials
}

# создаём txt-файл подписки
create_subscription_file() {
	local domain="$1"
	local encoded_wspath=$(urlencode "$WSPATH")
	local vless_link="vless://${UUID}@${domain}:443/?type=ws&path=${encoded_wspath}&security=tls#${domain}"
	
	cat > "/tmp/$SUBSCRIPTION_FILE" << EOF
#profile-update-interval: 1
#profile-title: base64:ZWFzeS12ay10dW5uZWw=
$vless_link
EOF
	
	log "Файл подписки создан: /tmp/$SUBSCRIPTION_FILE"
}

# загружаем подписку в s3 яндекса
upload_to_yandex_cloud() {
	local domain="$1"
	
	create_subscription_file "$domain"
	
	log "Загрузка файла подписки в бакет $BUCKET_NAME..."
	
	if $AWS_CMD --endpoint-url=https://storage.yandexcloud.net s3 cp "/tmp/$SUBSCRIPTION_FILE" "s3://$BUCKET_NAME/" > /dev/null 2>&1; then
		local file_url="https://storage.yandexcloud.net/$BUCKET_NAME/$SUBSCRIPTION_FILE"
		log "Файл подписки успешно загружен: $file_url"
		echo "Добавьте $file_url в своё VLESS-приложение, как подписку. Далее надзорный скрипт watchdog будет сам следить за работоспособностью туннеля, перезагружать его и автоматически менять домен в подписке."
	else
		log "Ошибка загрузки файла в бакет"
		return 1
	fi
}

# чекер работоспособности туннеля
check_tunnel() {
	local domain="$1"
	local url="https://${domain}${WSPATH}"
	local response
	local exit_code
	local success_count=0
	local attempt
	
	for attempt in {1..5}; do
		log "Проверка туннеля $domain (попытка $attempt/5)..."
		
		response=$($CURL_CMD -sk --max-time 5 "$url" 2>/dev/null)
		exit_code=$?
		
		if [[ $exit_code -eq 0 ]]; then
			if echo "$response" | grep -q "Bad Request"; then
				log "Туннель корректно отвечает ($domain) - попытка $attempt/5"
				((success_count++))
				
				# Если хотя бы одна успешная проверка - сразу возвращаем успех
				if [[ $success_count -ge 1 ]]; then
					# log "Туннель стабильно работает ($domain)."
					return 0
				fi
			else
				log "Проблема с туннелем ($domain). Неверный ответ - попытка $attempt/5. Ответ: $response"
				
				# Немедленный возврат ошибки при обнаружении "no tunnel connection"
				if echo "$response" | grep -q "there is no tunnel connection associated with given host"; then
					log "Туннель не ассоциирован с доменом. Немедленная перезагрузка."
					return 1
				fi
			fi
		else
			log "Ошибка проверки туннеля (curl exit code: $exit_code) - попытка $attempt/5"
		fi
		
		# Если это не последняя попытка - ждем перед следующей
		if [[ $attempt -lt 5 ]]; then
			sleep 2
		fi
	done
	
	# Если дошли до сюда, значит все попытки неудачные или недостаточно успешных
	if [[ $success_count -eq 0 ]]; then
		# log "Все 5 попыток проверки туннеля $domain завершились неудачно"
		return 1
	else
		# log "Туннель $domain работает нестабильно. Успешных проверок: $success_count/5"
		return 0
	fi
}

# запускаем туннель
start_vk_tunnel() {
	log "Запуск vk-tunnel на порту $INBOUNDPORT..."
	
	$PKILL_CMD -f "vk-tunnel"
	sleep 2
	
	$VK_TUNNEL_CMD --port="$INBOUNDPORT" > /tmp/vk-tunnel.log 2>&1 &
	
	# цикл проверки домена
	log "Ожидание появления домена в логах..."
	local domain=""
	
	for ((i=1; i<=30; i++)); do
		sleep 1
		domain=$(get_current_domain)
		if [[ -n "$domain" ]]; then
			log "Домен найден: $domain (попытка $i/30)"
			break
		fi
		log "Домен еще не появился в логах... (попытка $i/30)"
	done
	
	if [[ -z "$domain" ]]; then
		log "Ошибка: домен не найден в логах после 30 секунд ожидания"
		return 1
	fi
	
	local vk_pid=$(pgrep -f "vk-tunnel --port=$INBOUNDPORT")
	if [[ -z "$vk_pid" ]]; then
		log "Ошибка: vk-tunnel не запустился"
		return 1
	fi
	
	log "vk-tunnel запущен (PID: $vk_pid)"
	return 0
}

# получаем домен туннеля из вывода после запуска
get_current_domain() {
	local domain
	
	# Извлекаем домен из логов
	domain=$(grep -oE 'https://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' /tmp/vk-tunnel.log 2>/dev/null | tail -n 5 | sed 's|https://||')
	
	if [[ -z "$domain" ]]; then
		domain=$(grep -oE 'wss://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' /tmp/vk-tunnel.log 2>/dev/null | tail -n 5 | sed 's|wss://||')
	fi
	
	echo "$domain"
}

# принудительная повторная загрузка файла подписки
force_upload() {
	log "Принудительная загрузка файла подписки..."
	
	if ! read_config; then
		log "Ошибка: Конфигурационный файл не найден. Запустите --install сначала."
		exit 1
	fi
	
	if [[ -z "$LAST_DOMAIN" ]]; then
		log "Ошибка: LAST_DOMAIN не установлен в конфиге"
		exit 1
	fi
	
	local file_url
	file_url=$(upload_to_yandex_cloud "$LAST_DOMAIN")
	
	if [[ $? -eq 0 ]]; then
		log "Принудительная загрузка успешно завершена: $file_url"
	else
		log "Ошибка принудительной загрузки"
		exit 1
	fi
}

# процесс установки
install() {
	log "Начало установки Easy VK Tunnel v2.0"
	
	echo "Введите UUID:"
	read -r UUID
	
	echo "Введите порт инбаунда:"
	read -r INBOUNDPORT
	
	echo "Введите путь инбаунда (по умолчанию: /):"
	read -r WSPATH
	WSPATH="${WSPATH:-"/"}"
	
	echo "Введите название файла подписки (по умолчанию: tunnel.txt):"
	read -r SUBSCRIPTION_FILE
	SUBSCRIPTION_FILE=${SUBSCRIPTION_FILE:-"tunnel.txt"}
	
	echo "Введите имя бакета:"
	read -r BUCKET_NAME
	
	echo "Введите идентификатор статического доступа сервисного аккаунта:"
	read -r SA_ACCESS_KEY_ID
	
	echo "Введите ключ статического доступа сервисного аккаунта:"
	read -r SA_SECRET_ACCESS_KEY
	echo
	
	# установка зависимостей
	install_dependencies
	
	# проверяем установку
	if ! check_commands; then
		log "Ошибка: не все необходимые команды установлены"
		exit 1
	fi
	
	# настройка awscli
	configure_aws
	
	# сохраняем конфиг
	write_config
	
	# запускаем vk-tunnel
	if ! start_vk_tunnel; then
		log "Ошибка при запуске vk-tunnel"
		exit 1
	fi
	
	# получаем домен
	local domain
	domain=$(get_current_domain)
	if [[ -z "$domain" ]]; then
		log "Ошибка: не удалось получить домен vk-tunnel"
		exit 1
	fi
	
	# обновляем конфиг, вписываем в него последний домен
	LAST_DOMAIN="$domain"
	write_config
	
	# создаём и загружаем txt подписки в s3 яндекса
	local file_url
	file_url=$(upload_to_yandex_cloud "$domain")
	
	# добавляем в cron
	local script_path="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
	
	# Проверяем, существует ли файл скрипта
	if [[ ! -f "$script_path" ]]; then
		log "Ошибка: скрипт не найден по пути: $script_path"
		return 1
	fi
	
	log "Добавление в cron: $script_path"
	(crontab -l 2>/dev/null | grep -v "$script_path"; echo "* * * * * /bin/bash '$script_path' --watchdog") | crontab -
	log "Задача добавлена в cron"
	
	log "Установка завершена. Watchdog добавлен в cron."
	log "Логи: $LOG_FILE"
	
	# фикс: отображение URL подписки после установки
	if [[ -n "$file_url" ]]; then
		echo "================URL подписки=================="
		echo "$file_url"
		echo "=============================================="
	fi
}

# надзорный скрипт watchdog
watchdog() {
	log "Запуск watchdog-проверки"
	
	if ! read_config; then
		log "Ошибка: не удалось прочитать конфигурацию"
		exit 1
	fi
	
	if ! check_commands; then
		log "Ошибка: не все необходимые команды доступны"
		exit 1
	fi
	
	# чекаем туннель
	if check_tunnel "$LAST_DOMAIN"; then
		log "Ничего не делаем, всё хорошо"
		exit 0
	fi
	
	log "Обнаружена проблема с туннелем. Перезапуск..."
	
	# рестарт туннеля
	if ! start_vk_tunnel; then
		log "Критическая ошибка: не удалось перезапустить vk-tunnel"
		exit 1
	fi
	
	# смотрим на то, какой домен выдал вк
	local new_domain
	new_domain=$(get_current_domain)
	
	if [[ -z "$new_domain" ]]; then
		log "Ошибка: не удалось получить новый домен"
		exit 1
	fi
	
	log "Новый домен: $new_domain"
	
	# если домен изменился, обновляем файл подписки
	if [[ "$new_domain" != "$LAST_DOMAIN" ]]; then
		log "Домен изменился. Обновление файла подписки..."
		
		if upload_to_yandex_cloud "$new_domain"; then
			LAST_DOMAIN="$new_domain"
			write_config
			log "Файл подписки успешно обновлен"
		else
			log "Ошибка обновления файла подписки"
		fi
	else
		log "Домен не изменился"
	fi
	
	log "Watchdog проверка завершена"
}

# скрипт запуска туннеля
run_tunnel() {
	if ! read_config; then
		log "Ошибка: Конфигурационный файл не найден. Запустите сначала --install."
		exit 1
	fi
	
	start_vk_tunnel
}

# логика
case "${1:-}" in
	"--install")
		install
		;;
	"--watchdog")
		watchdog
		;;
	"--run")
		run_tunnel
		;;
	"--force-upload")
		force_upload
		;;
	*)
		echo "Использование: $0 [OPTION]"
		echo ""
		echo "Опции:"
		echo "  --install        Установка и настройка скрипта"
		echo "  --watchdog       Запуск надзорного скрипта watchdog (для cron)"
		echo "  --run            Запуск туннеля с текущей конфигурацией"
		echo "  --force-upload   Принудительная повторная загрузка файла подписки в Yandex.Cloud"
		echo ""
		echo "Пример: $0 --install"
		echo "Пример: $0 --force-upload"
		;;
esac
