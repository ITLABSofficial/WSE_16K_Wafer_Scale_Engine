CC = gcc
CFLAGS = -O3 -Wall -Wextra -std=c11 -lm

TARGET = ara_wse_16384core_test_runner
SRCS = ara_wse_16384core_test_runner.c ara_wse_16384core_driver.c

all: $(TARGET)

$(TARGET): $(SRCS) ara_wse_16384core_driver.h
	$(CC) $(CFLAGS) -o $(TARGET) $(SRCS)

test: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET) *.o
