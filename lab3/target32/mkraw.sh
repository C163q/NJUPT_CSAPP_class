if [ -n "$1" ]; then
    ./hex2raw < "$1" > attack.txt
else
    echo "provide \$1"
fi


