    { sub(/\r$/, "") }
    /^[0-9]+ (file|files|output|outputs) / || /^No (files changed|outputs declared)\.$/ || /^unavailable — / { print; exit }
  
