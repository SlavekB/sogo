/* SOGoWebAuthenticator.m - this file is part of SOGo
 *
 * Copyright (C) 2007-2014 Inverse inc.
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */


#import <NGObjWeb/SoDefaultRenderer.h>
#import <NGObjWeb/WOApplication.h>
#import <NGObjWeb/WOCookie.h>
#import <NGObjWeb/WORequest.h>
#import <NGObjWeb/WOResponse.h>
#import <NGExtensions/NGBase64Coding.h>
#import <NGExtensions/NSCalendarDate+misc.h>
#import <NGExtensions/NSData+gzip.h>
#import <NGExtensions/NSObject+Logs.h>
#import <NGExtensions/NSNull+misc.h>
#import <NGExtensions/NSString+Ext.h>

#import <MainUI/SOGoRootPage.h>

#import "SOGoCache.h"
#import "SOGoCASSession.h"
#import "SOGoOpenIdSession.h"
#import "SOGoPermissions.h"
#import "SOGoSession.h"
#import "SOGoSystemDefaults.h"
#import "SOGoUser.h"
#import "SOGoUserManager.h"
#if defined(SAML2_CONFIG)
#import "SOGoSAML2Session.h"
#endif
#import "SOGoWebAuthenticator.h"

#define COOKIE_SESSIONKEY_LEN 16
/**
   The base64 encoded key XORed with the cookie value. It must fit in the
   database field which is 4096 char long. The browser cookie limit is
   about the same. The length is prior to bas64 encoding, so we must calculate
   a 33-36% increase.
 */
#define COOKIE_USERKEY_LEN    2096

@implementation SOGoWebAuthenticator

+ (id) sharedSOGoWebAuthenticator
{
  static SOGoWebAuthenticator *auth = nil;
 
  if (!auth)
    auth = [self new];

  return auth;
}

- (BOOL) checkLogin: (NSString *) _login
           password: (NSString *) _pwd
{ 
  NSString *username, *password, *domain, *value;
  SOGoPasswordPolicyError perr;
  int expire, grace;
 

  // We check for the existence of the session in the database/memcache
  // and we extract the real password from it. Here,
  //
  // _login == userKey
  // _pwd == sessionKey
  //
  // If the session isn't present in the database, we fail the login process.
  //
  value = [SOGoSession valueForSessionKey: _pwd];

  if (!value)
    {
      [self logWithFormat:@"Expired session received, redirecting to login page."];
      return NO;
    }

  domain = nil;
  [SOGoSession decodeValue: value
                  usingKey: _login
                     login: &username
                    domain: &domain
                  password: &password];

  return [self checkLogin: username
                 password: password
                   domain: &domain
                     perr: &perr
                   expire: &expire
                    grace: &grace
           additionalInfo: nil];
}

- (BOOL) checkLogin: (NSString *) _login
           password: (NSString *) _pwd
             domain: (NSString **) _domain
               perr: (SOGoPasswordPolicyError *) _perr
             expire: (int *) _expire
              grace: (int *) _grace
     additionalInfo: (NSMutableDictionary **)_additionalInfo
{
  return [self checkLogin: _login
                 password: _pwd
                   domain: _domain
                     perr: _perr
                   expire: _expire
                    grace: _grace
           additionalInfo: _additionalInfo
                 useCache: YES];
}

- (BOOL) checkLogin: (NSString *) _login
           password: (NSString *) _pwd
             domain: (NSString **) _domain
               perr: (SOGoPasswordPolicyError *) _perr
             expire: (int *) _expire
              grace: (int *) _grace
     additionalInfo: (NSMutableDictionary **)_additionalInfo
           useCache: (BOOL) _useCache
{
  SOGoCASSession *casSession;
  SOGoOpenIdSession * openIdSession;
  SOGoSystemDefaults *sd;
  NSString *authenticationType;
  NSString* loginDomain;
  BOOL rc;

  sd = [SOGoSystemDefaults sharedSystemDefaults];
  
  //Basic check
  if(!_login)
    return NO;
  if(_login && [_login length] == 0)
    return NO;

  loginDomain = nil;
  if(*_domain == nil || [*_domain length] == 0)
  {
      NSRange r;
      r = [_login rangeOfString: @"@"];
      if (r.location != NSNotFound)
      {
        loginDomain = [_login substringFromIndex: r.location+1];
      }
  }

  if([sd doesLoginTypeByDomain])
    authenticationType = [sd getLoginTypeForDomain: loginDomain];
  else
    authenticationType = [sd authenticationType];

  if ([authenticationType isEqualToString: @"cas"])
    {
      casSession = [SOGoCASSession CASSessionWithIdentifier: _pwd fromProxy: NO];
      if (casSession)
        rc = [[casSession login] isEqualToString: _login];
      else
        rc = NO;
    }
  else if ([authenticationType isEqualToString: @"openid"])
  {
    openIdSession = [SOGoOpenIdSession OpenIdSessionWithToken: _pwd domain: loginDomain];
    if (openIdSession)
      rc = [[openIdSession login: _login] isEqualToString: _login];
    else
      rc = NO;
  }
#if defined(SAML2_CONFIG)
  else if ([authenticationType isEqualToString: @"saml2"])
    {
      SOGoSAML2Session *saml2Session;
      WOContext *context;

      context = [[WOApplication application] context];
      saml2Session = [SOGoSAML2Session SAML2SessionWithIdentifier: _pwd
                                                        inContext: context];
      rc = [[saml2Session login] isEqualToString: _login];
    }
#endif /* SAML2_CONFIG */
  else
    rc = [[SOGoUserManager sharedUserManager] checkLogin: _login
                                                password: _pwd
                                                  domain: _domain
                                                    perr: _perr
                                                  expire: _expire
                                                   grace: _grace
                                          additionalInfo: _additionalInfo
                                                useCache: _useCache];
  //[self logWithFormat: @"Checked login with ppolicy enabled: %d %d %d", *_perr, *_expire, *_grace];
  
  // It's important to return the real value here. The callee will handle
  // the return code and check for the _perr value.
  return rc;
}

//
//
//
- (SOGoUser *) userInContext: (WOContext *)_ctx
{
  static SOGoUser *anonymous = nil;
  SOGoUser *user;

  user = (SOGoUser *) [super userInContext: _ctx];
  if (!user || [[user login] isEqualToString: @"anonymous"])
    {
      if (!anonymous)
        anonymous = [[SOGoUser alloc]
                      initWithLogin: @"anonymous"
                              roles: [NSArray arrayWithObject: SoRole_Anonymous]];
      user = anonymous;
    }

  return user;
}

- (NSString *) passwordInContext: (WOContext *) context
{
  NSString *auth, *password;
  NSArray *creds;

  auth = [[context request]
           cookieValueForKey: [self cookieNameInContext: context]];
  creds = [self parseCredentials: auth];
  if ([creds count] > 1)
    {
      NSString *login, *domain;
      
      [SOGoSession decodeValue: [SOGoSession valueForSessionKey: [creds objectAtIndex: 1]]
                      usingKey: [creds objectAtIndex: 0]
                         login: &login
                        domain: &domain
                      password: &password];
    }
  else
    password = nil;

  return password;
}

//
// We overwrite SOPE's method in order to proper retrieve
// the username from the cookie.
//
- (NSString *) checkCredentials: (NSString *)_creds
{
  NSString *login, *domain, *pwd, *userKey, *sessionKey;
  NSArray *creds;

  SOGoPasswordPolicyError perr;
  int expire, grace;
  
  if (![(creds = [self parseCredentials:_creds]) isNotEmpty])
    return nil;

  userKey = [creds objectAtIndex:0];
  if ([userKey isEqualToString:@"anonymous"])
    return @"anonymous";
  
  sessionKey = [creds objectAtIndex:1];
  
  [SOGoSession decodeValue: [SOGoSession valueForSessionKey: sessionKey]
                  usingKey: userKey
                     login: &login
                    domain: &domain
                  password: &pwd];


  if (![self checkLogin: login
               password: pwd
                 domain: &domain
                   perr: &perr
                 expire: &expire
                  grace: &grace
         additionalInfo: nil])
    return nil;
  
  if (domain && [login rangeOfString: @"@"].location == NSNotFound)
    login = [NSString stringWithFormat: @"%@@%@", login, domain];

  return login;
}


- (NSString *) imapPasswordInContext: (WOContext *) context
                              forURL: (NSURL *) server
                          forceRenew: (BOOL) renew
{
  NSString *authType, *password;
  SOGoSystemDefaults *sd;
  SOGoUser *user;
  NSRange r;
  NSString *loginDomain, *login;
 
  password = [self passwordInContext: context];
  if ([password length])
    {
      user = [self userInContext: context];
      login = [user loginInDomain];
      r = [login rangeOfString: @"@"];
      if (r.location != NSNotFound)
        loginDomain = [login substringFromIndex: r.location+1];
      else
        loginDomain = nil;

      sd = [SOGoSystemDefaults sharedSystemDefaults];
      if([sd doesLoginTypeByDomain])
        authType = [sd getLoginTypeForDomain: loginDomain];
      else
        authType = [sd authenticationType];

      if ([authType isEqualToString: @"cas"])
        {
          SOGoCASSession *session;
          NSString *service, *scheme;

          session = [SOGoCASSession CASSessionWithIdentifier: password
                                                   fromProxy: NO];
          // Try configured CAS service name first
          service = [[user domainDefaults] imapCASServiceName];
          if (!service)
            {
              // We must NOT assume the scheme exists
              scheme = [server scheme];
              if (!scheme)
                scheme = @"imap";
              service = [NSString stringWithFormat: @"%@://%@",
                         scheme, [server host]];
            }

          if (renew)
            [session invalidateTicketForService: service];

          password = [session ticketForService: service];
          if ([password length] || renew)
            [session updateCache];
        }
      else if ([authType isEqualToString: @"openid"])
      {
        SOGoOpenIdSession* session;

        //If the token has been refresh during the request, we need to use the new access_token
        //as the one from the cookie is no more valid
        session = [SOGoOpenIdSession OpenIdSessionWithToken: password domain: loginDomain];
        password = [session getCurrentToken];
      }
#if defined(SAML2_CONFIG)
      else if ([authType isEqualToString: @"saml2"])
        {
          SOGoSAML2Session *session;
          WOContext *context;
          NSData *assertion;

          context = [[WOApplication application] context];
          session = [SOGoSAML2Session SAML2SessionWithIdentifier: password
                                                       inContext: context];
          assertion = [[session assertion]
                        dataUsingEncoding: NSUTF8StringEncoding];
          password = [[[assertion compress] stringByEncodingBase64]
                       stringByReplacingString: @"\n"
                                    withString: @""];
        }
#endif
    }

  return password;
}

- (NSString *) smtpPasswordInContext: (WOContext *) context
                              forURL: (NSURL *) server
{
  NSString *password;

  password = [self imapPasswordInContext: context forURL: server forceRenew:NO];

  return password;
}

/* create SOGoUser */

- (SOGoUser *) userWithLogin: (NSString *) login
                    andRoles: (NSArray *) roles
                   inContext: (WOContext *) ctx
{
  /* the actual factory method */
  return [SOGoUser userWithLogin: login roles: roles];
}

//
// This is called by SoObjectRequestHandler prior doing any significant
// processing to allow the authenticator to reject invalid requests.
//
- (WOResponse *) preprocessCredentialsInContext: (WOContext *) context
{
  WOResponse *response;
  NSString *auth;

  auth = [[context request]
           cookieValueForKey: [self cookieNameInContext:context]];
  if ([auth isEqualToString: @"discard"])
    {
      [context setObject: [NSArray arrayWithObject: SoRole_Anonymous]
                  forKey: @"SoAuthenticatedRoles"];
      response = nil;
    }
  else
    response = [super preprocessCredentialsInContext: context];

  return response;
}

- (void) setupAuthFailResponse: (WOResponse *) response
                    withReason: (NSString *) reason
                     inContext: (WOContext *) context
{
  WOComponent *page;
  WORequest *request;
  WOCookie *authCookie;
  NSCalendarDate *date;
  NSString *appName;

  request = [context request];
  page = [[WOApplication application] pageWithName: @"SOGoRootPage"
                                        forRequest: request];
  [[SoDefaultRenderer sharedRenderer] renderObject: [page defaultAction]
                                         inContext: context];
  authCookie = [WOCookie cookieWithName: [self cookieNameInContext: context]
                                  value: @"discard"];
  appName = [request applicationName];
  [authCookie setPath: [NSString stringWithFormat: @"/%@/", appName]];
  date = [NSCalendarDate calendarDate];
  [authCookie setExpires: [date yesterday]];
  [response addCookie: authCookie];
}

- (WOCookie *) cookieWithUsername: (NSString *) username
                      andPassword: (NSString *) password
                        inContext: (WOContext *) context
{
  WOCookie *authCookie;
  NSString *cookieValue, *cookieString, *appName, *sessionKey, *userKey, *securedPassword;
  BOOL isSecure;

  //
  // We create a new cookie - thus we create a new session
  // associated to the user. For security, we generate:
  //
  // A- a session key
  // B- a user key
  //
  // In memcached, the session key will be associated to the user's password
  // which will be XOR'ed with the user key.
  //
  sessionKey = [SOGoSession generateKeyForLength: COOKIE_SESSIONKEY_LEN];
  userKey = [SOGoSession generateKeyForLength: COOKIE_USERKEY_LEN];

  NSString *value = [NSString stringWithFormat: @"%@:%@", username, password];
  securedPassword = [SOGoSession securedValue: value  usingKey: userKey];


  [SOGoSession setValue: securedPassword  forSessionKey: sessionKey];

  //cookieString = [NSString stringWithFormat: @"%@:%@",
  //                         username, password];
  cookieString = [NSString stringWithFormat: @"%@:%@",
                           userKey, sessionKey];
  cookieValue = [NSString stringWithFormat: @"basic %@",
                          [cookieString stringByEncodingBase64]];
  isSecure = [[[context serverURL] scheme] isEqualToString: @"https"];
  authCookie = [WOCookie cookieWithName: [self cookieNameInContext: context]
                                  value: cookieValue
                                   path: nil
                                 domain: nil
                                expires: nil
                               isSecure: isSecure
                               httpOnly: YES];
  appName = [[context request] applicationName];
  [authCookie setPath: [NSString stringWithFormat: @"/%@/", appName]];
  
  return authCookie;
}

- (NSArray *) getCookiesIfNeeded: (WOContext *)_ctx
{
  NSArray *listCookies = nil;
  SOGoSystemDefaults *sd;
  NSString *authType, *username, *login, *loginDomain;
  NSRange r;
  SOGoUser *user;

  user = [self userInContext: _ctx];
  login = [user loginDomain];
  r = [login rangeOfString: @"@"];
  if (r.location != NSNotFound)
    loginDomain = [login substringFromIndex: r.location+1];
  else
    loginDomain = nil;

  sd = [SOGoSystemDefaults sharedSystemDefaults];
  if(loginDomain && [sd doesLoginTypeByDomain])
    authType = [sd getLoginTypeForDomain: loginDomain];
  else
    authType = [sd authenticationType];
  if([authType isEqualToString:@"openid"] && [sd openIdEnableRefreshToken])
  {
    NSString *currentPassword, *newPassword;
    SOGoOpenIdSession *openIdSession;
    WOCookie* newCookie;


    currentPassword = [self passwordInContext: _ctx];
    newPassword = [self imapPasswordInContext: _ctx forURL: nil forceRenew: NO];
    if(currentPassword && newPassword && ![newPassword isEqualToString: currentPassword])
    {

      openIdSession = [SOGoOpenIdSession OpenIdSessionWithToken: newPassword domain: loginDomain];
      if (openIdSession)
        username = [openIdSession login: @""]; //Force to refresh the name
      else
        username = [[self userInContext: _ctx] login];
      newCookie = [self cookieWithUsername: username
                               andPassword: newPassword
                                 inContext: _ctx];
      listCookies = [[NSArray alloc] initWithObjects: newCookie, nil];
      [listCookies autorelease];
    }
    if(listCookies && [listCookies isKindOfClass:[NSArray class]] && [listCookies count] > 0)
      return listCookies;
    else
      return nil;
  }
  else
    return nil;
}

@end /* SOGoWebAuthenticator */
