case $- in
  *i*) ;;
  *) return 0 ;;
esac

. "${${(%):-%N}:A:h}/common.sh" "${${(%):-%N}:A:h}/../bin"
