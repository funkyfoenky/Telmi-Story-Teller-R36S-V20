#ifndef STORYTELLER_TIME_HELPER__
#define STORYTELLER_TIME_HELPER__

#include <stdbool.h>
#include <time.h>


static long int get_time(void)
{
    return (long int) time(0);
}

static unsigned long time_lastTime = 0;

static bool time_wait(void)
{
    unsigned long currentTime = clock() * 1000 / CLOCKS_PER_SEC;
    if ((currentTime - time_lastTime) > 50) {
        time_lastTime = currentTime;
        return true;
    }
    return false;
}


#endif // STORYTELLER_TIME_HELPER__
