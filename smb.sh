#!/bin/bash
# acessar_samba.sh - Interface fácil para acessar Samba

clear
echo "╔══════════════════════════════════════════╗"
echo "║         ACESSADOR DE COMPARTILHAMENTOS   ║"
echo "║                SAMBA                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Configurações padrão (do servidor_completo.sh)
SERVER_DEFAULT="192.168.0.1"
SHARE_DEFAULT="Compartilhado"

# Solicitar informações
read -p "IP do servidor [$SERVER_DEFAULT]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$SERVER_DEFAULT}

read -p "Nome do compartilhamento [$SHARE_DEFAULT]: " SHARE_NAME
SHARE_NAME=${SHARE_NAME:-$SHARE_DEFAULT}

echo ""
echo "Selecione o método de acesso:"
echo "1) smbclient (linha de comando interativa)"
echo "2) Montar em /mnt/samba (acesso via arquivos)"
echo "3) gio mount (para interface gráfica)"
echo "4) Apenas listar compartilhamentos"
echo "5) Copiar arquivo para o compartilhamento"
echo "6) Copiar arquivo do compartilhamento"
echo "0) Sair"
echo ""

read -p "Opção: " OPCAO

case $OPCAO in
    1)
        echo "Conectando ao compartilhamento..."
        echo "Comandos úteis: ls, get, put, mkdir, rm, exit"
        echo "Pressione Enter para continuar..."
        read
        smbclient //$SERVER_IP/$SHARE_NAME -N
        ;;
    
    2)
        echo "Montando compartilhamento..."
        sudo mkdir -p /mnt/samba 2>/dev/null
        
        if sudo mount -t cifs //$SERVER_IP/$SHARE_NAME /mnt/samba -o guest; then
            echo "✅ Montado com sucesso em /mnt/samba"
            echo ""
            echo "Conteúdo:"
            ls -la /mnt/samba/
            echo ""
            echo "Para desmontar: sudo umount /mnt/samba"
        else
            echo "❌ Falha ao montar"
            echo "Tentando com opções adicionais..."
            sudo mount -t cifs //$SERVER_IP/$SHARE_NAME /mnt/samba -o guest,vers=2.0
        fi
        ;;
    
    3)
        echo "Montando para interface gráfica..."
        if gio mount "smb://$SERVER_IP/$SHARE_NAME"; then
            echo "✅ Montado com sucesso"
            echo "Acesse via: smb://$SERVER_IP/$SHARE_NAME"
        else
            echo "❌ Falha ao montar"
            echo "Instalando suporte: sudo apt install gvfs-backends-smb"
        fi
        ;;
    
    4)
        echo "Compartilhamentos disponíveis em $SERVER_IP:"
        echo "══════════════════════════════════════════"
        smbclient -L $SERVER_IP -N
        ;;
    
    5)
        read -p "Caminho do arquivo local para copiar: " ARQUIVO_LOCAL
        read -p "Nome no destino (Enter para mesmo nome): " ARQUIVO_DESTINO
        ARQUIVO_DESTINO=${ARQUIVO_DESTINO:-$(basename "$ARQUIVO_LOCAL")}
        
        if [ -f "$ARQUIVO_LOCAL" ]; then
            echo "Copiando $ARQUIVO_LOCAL para //$SERVER_IP/$SHARE_NAME/$ARQUIVO_DESTINO"
            smbclient //$SERVER_IP/$SHARE_NAME -N -c "put \"$ARQUIVO_LOCAL\" \"$ARQUIVO_DESTINO\""
        else
            echo "Arquivo não encontrado: $ARQUIVO_LOCAL"
        fi
        ;;
    
    6)
        echo "Arquivos disponíveis:"
        smbclient //$SERVER_IP/$SHARE_NAME -N -c "ls" | tail -n +4
        
        read -p "Nome do arquivo para copiar: " ARQUIVO_REMOTO
        read -p "Nome local (Enter para mesmo nome): " ARQUIVO_LOCAL
        ARQUIVO_LOCAL=${ARQUIVO_LOCAL:-$ARQUIVO_REMOTO}
        
        echo "Copiando //$SERVER_IP/$SHARE_NAME/$ARQUIVO_REMOTO para $ARQUIVO_LOCAL"
        smbclient //$SERVER_IP/$SHARE_NAME -N -c "get \"$ARQUIVO_REMOTO\" \"$ARQUIVO_LOCAL\""
        ;;
    
    0)
        echo "Saindo..."
        exit 0
        ;;
    
    *)
        echo "Opção inválida"
        ;;
esac

echo ""
echo "══════════════════════════════════════════"
echo "Comandos manuais úteis:"
echo "• Listar: smbclient -L $SERVER_IP -N"
echo "• Acessar: smbclient //$SERVER_IP/$SHARE_NAME -N"
echo "• Montar: sudo mount -t cifs //$SERVER_IP/$SHARE_NAME /mnt/samba -o guest"
echo "• GUI: Navegue para smb://$SERVER_IP/$SHARE_NAME"
echo "══════════════════════════════════════════"
