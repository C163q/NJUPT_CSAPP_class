
export ATTACKLAB_PARAM=""
export ATTACKLAB_APP=""

if [ "$1" == "c" ]; then
    ATTACKLAB_APP="./ctarget"
    if [ -z "$2" ]; then
        ATTACKLAB_PARAM="-q"
    fi
    gdb $ATTACKLAB_APP --command="my_data/setup"
elif [ "$1" == "r" ]; then
    ATTACKLAB_APP="./rtarget"
    if [ -z "$2" ]; then
        ATTACKLAB_PARAM="-q"
    fi
    gdb $ATTACKLAB_APP --command="my_data/setup"
else
    echo "provide 'c' or 'r'"
fi

unset ATTACKLAB_APP
unset ATTACKLAB_PARAM

