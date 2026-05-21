code() {
  if [ -z "$1" ]; then
    codium -n .
  else
    codium -n "$@"
  fi
}