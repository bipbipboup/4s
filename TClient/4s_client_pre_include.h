// 4s_client_pre_include.h
// Pre-include force pour compatibilite VS2017 / Windows 10 SDK

// Cible Windows XP+ minimum
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#ifndef WINVER
#define WINVER 0x0501
#endif

// MFC CX_BORDER/CY_BORDER renommes AFX_CX_BORDER en VS2017
#ifndef CX_BORDER
#define CX_BORDER 1
#endif
#ifndef CY_BORDER
#define CY_BORDER 1
#endif