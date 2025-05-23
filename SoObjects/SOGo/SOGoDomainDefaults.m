/* SOGoDomainDefaults.m - this file is part of SOGo
 *
 * Copyright (C) 2009-2019 Inverse inc.
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

#import <Foundation/NSDictionary.h>
#import <NGObjWeb/WOApplication.h>
#import <NGObjWeb/WOContext.h>
#import <NGObjWeb/WORequest.h>
#import <NGExtensions/NSObject+Logs.h>

#import "SOGoSystemDefaults.h"


@implementation SOGoDomainDefaults

+ (SOGoDomainDefaults *) defaultsForDomain: (NSString *) domainId
{
  NSDictionary *domainValues;
  SOGoSystemDefaults *systemDefaults;
  SOGoDomainDefaults *domainDefaults;

  domainDefaults = nil;

  if ([domainId length])
    {
      systemDefaults = [SOGoSystemDefaults sharedSystemDefaults];
      domainValues = [[systemDefaults dictionaryForKey: @"domains"]
                       objectForKey: domainId];
      if ([domainValues isKindOfClass: [NSDictionary class]])
        domainDefaults = [self defaultsSourceWithSource: domainValues
                                        andParentSource: systemDefaults];
    }

  if (!domainDefaults)
    domainDefaults = [SOGoSystemDefaults sharedSystemDefaults];

  return domainDefaults;
}

- (BOOL) migrate
{
  static NSDictionary *migratedKeys = nil;

  if (!migratedKeys)
    {
      migratedKeys
        = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"SOGoIMAPServer", @"SOGoFallbackIMAP4Server",
                        @"SOGoMailDomain", @"SOGoDefaultMailDomain",
                        @"SOGoLDAPContactInfoAttribute", @"LDAPContactInfoAttribute",
                        @"SOGoUserSources", @"SOGoLDAPSources",
                        @"SOGoMailKeepDraftsAfterSend", @"SOGoNoDraftDeleteAfterSend",
                        @"SOGoMailAttachTextDocumentsInline", @"SOGoShowTextAttachmentsInline",
                        nil];
      [migratedKeys retain];
    }

  /* we must not use a boolean operation, otherwise subsequent migrations will
     not even occur in the case where rc = YES. */
  return ([self migrateOldDefaultsWithDictionary: migratedKeys]
          | [super migrate]);
}

- (NSArray *) userSources
{
  return [source objectForKey: @"SOGoUserSources"];
}

/* System-/Domain-level */

// SOGoDontUseETagsForMailViewer

- (NSString *) profileURL
{
  return [self stringForKey: @"SOGoProfileURL"];
}

- (NSString *) folderInfoURL
{
  return [self stringForKey: @"OCSFolderInfoURL"];
}

- (BOOL) mailCustomFromEnabled
{
  return [self boolForKey: @"SOGoMailCustomFromEnabled"];
}

- (BOOL) mailAuxiliaryUserAccountsEnabled
{
  return [self boolForKey: @"SOGoMailAuxiliaryUserAccountsEnabled"];
}

- (BOOL) mailDisableXForward
{
  return [self boolForKey: @"SOGoMailDisableXForward"];
}

- (NSString *) mailDomain
{
  return [self stringForKey: @"SOGoMailDomain"];
}

- (NSString *) imapServer
{
  return [self stringForKey: @"SOGoIMAPServer"];
}

- (NSString *) sieveServer
{
  return [self stringForKey: @"SOGoSieveServer"];
}

- (NSString *) imapCASServiceName
{
  return [self objectForKey: @"SOGoIMAPCASServiceName"];
}

#warning should be removed when we make use of imap namespace
- (NSString *) imapAclStyle
{
  return [self stringForKey: @"SOGoIMAPAclStyle"];
}

- (NSString *) imapAclGroupIdPrefix
{
  return [self stringForKey: @"NGImap4ConnectionGroupIdPrefix"];
}

#warning this should be determined from the capabilities
/* http://www.tools.ietf.org/wg/imapext/draft-ietf-imapext-acl/ */
- (BOOL) imapAclConformsToIMAPExt
{
  return [self boolForKey: @"SOGoIMAPAclConformsToIMAPExt"];
}

- (BOOL) aclSendEMailNotifications
{
  return [self boolForKey: @"SOGoACLsSendEMailNotifications"];
}

- (BOOL) appointmentSendEMailNotifications
{
  return [self boolForKey: @"SOGoAppointmentSendEMailNotifications"];
}

- (BOOL) foldersSendEMailNotifications
{
  return [self boolForKey: @"SOGoFoldersSendEMailNotifications"];
}

- (NSArray *) calendarDefaultRoles
{
  return [self stringArrayForKey: @"SOGoCalendarDefaultRoles"];
}

- (NSString *) calendarJitsiBaseUrl
{
  NSString *jitsiBaseUrl;
  jitsiBaseUrl = [self stringForKey: @"SOGoCalendarJitsiBaseUrl"];
  if(!jitsiBaseUrl)
    jitsiBaseUrl = @"https://meet.jit.si";

  return jitsiBaseUrl;
}

- (NSString *) calendarJitsiRoomPrefix
{
  NSString *jitsiRoomPrefix;
  jitsiRoomPrefix = [self stringForKey: @"SOGoCalendarJitsiRoomPrefix"];
  if(!jitsiRoomPrefix)
    jitsiRoomPrefix = @"SOGo_meeting/";

  return jitsiRoomPrefix;
}

- (NSArray *) contactsDefaultRoles
{
  return [self stringArrayForKey: @"SOGoContactsDefaultRoles"];
}

- (NSString *) subscriptionFolderFormat
{
  return [self stringForKey: @"SOGoSubscriptionFolderFormat"];
}

//
// In v2.0.4, SOGoForceIMAPLoginWithEmail was renamed to SOGoForceExternalLoginWithEmail
// but we keep backward compatbility for now with previous versions.
//
- (BOOL) forceExternalLoginWithEmail
{
  if ([self stringForKey: @"SOGoForceExternalLoginWithEmail"])
    return [self boolForKey: @"SOGoForceExternalLoginWithEmail"];

  return [self boolForKey: @"SOGoForceIMAPLoginWithEmail"];
}

- (BOOL) externalAvatarsEnabled
{
  return [self boolForKey: @"SOGoExternalAvatarsEnabled"];
}

- (BOOL) sieveScriptsEnabled
{
  return [self boolForKey: @"SOGoSieveScriptsEnabled"];
}

- (NSString *) sieveScriptHeaderTemplateFile
{
  return [self stringForKey: @"SOGoSieveScriptHeaderTemplateFile"];
}

- (NSString *) sieveScriptFooterTemplateFile
{
  return [self stringForKey: @"SOGoSieveScriptFooterTemplateFile"];
}

- (BOOL) forwardEnabled
{
  return [self boolForKey: @"SOGoForwardEnabled"];
}

- (int) forwardConstraints
{
  unsigned int v;

  v =  [self integerForKey: @"SOGoForwardConstraints"];
  
  return (v > 3 ? 0 : v);
}

- (NSArray *) forwardConstraintsDomains
{
  return [self stringArrayForKey: @"SOGoForwardConstraintsDomains"];
}

- (BOOL) notificationEnabled
{
  return [self boolForKey: @"SOGoNotificationEnabled"];
}

- (BOOL) vacationEnabled
{
  return [self boolForKey: @"SOGoVacationEnabled"];
}

- (BOOL) vacationPeriodEnabled
{
  id o;

  o = [self stringForKey: @"SOGoVacationPeriodEnabled"];

  if (o)
    return [o boolValue];

  return YES;
}

- (NSString *) vacationDefaultSubject
{
  return [self stringForKey: @"SOGoVacationDefaultSubject"];
}

- (NSString *) vacationHeaderTemplateFile
{
  return [self stringForKey: @"SOGoVacationHeaderTemplateFile"];
}

- (NSString *) vacationFooterTemplateFile
{
  return [self stringForKey: @"SOGoVacationFooterTemplateFile"];
}

- (BOOL) vacationAllowZeroDays
{
  id o;

  o = [self stringForKey: @"SOGoVacationAllowZeroDays"];

  if (o)
    return [o boolValue];

  return NO;
}

- (NSString *) mailingMechanism
{
  NSString *mailingMechanism;

  mailingMechanism = [self stringForKey: @"SOGoMailingMechanism"];
  if (!([mailingMechanism isEqualToString: @"sendmail"]
        || [mailingMechanism isEqualToString: @"smtp"]))
    {
      [self logWithFormat: @"mechanism '%@' is invalid and"
            @" should be set to 'sendmail' or 'smtp' instead",
            mailingMechanism];
      mailingMechanism = nil;
    }

  return [mailingMechanism lowercaseString];
}

- (NSArray *) refreshViewIntervals
{
  return [self arrayForKey: @"SOGoRefreshViewIntervals"];
}

- (NSString *) smtpServer
{
  NSString *server;
  server = [self stringForKey: @"SOGoSMTPServer"];
  // backwards compatibility
  if (![server hasPrefix: @"smtp://"] &&
      ![server hasPrefix: @"smtps://"])
    {
      return [NSString stringWithFormat: @"smtp://%@", server];
    }
  return server;
}

- (BOOL) smtpMasterUserEnabled
{
  return [self boolForKey: @"SOGoSMTPMasterUserEnabled"];
}

- (NSString *) smtpMasterUserUsername
{
  return [self stringForKey: @"SOGoSMTPMasterUserUsername"];
}

- (NSString *) smtpMasterUserPassword
{
  return [self stringForKey: @"SOGoSMTPMasterUserPassword"];
}

- (NSString *) smtpAuthenticationType
{
  return [[self stringForKey: @"SOGoSMTPAuthenticationType"] lowercaseString];
}

- (NSString *) mailSpoolPath
{
  return [self stringForKey: @"SOGoMailSpoolPath"];
}

- (float) softQuotaRatio
{
  return [self floatForKey: @"SOGoSoftQuotaRatio"];
}

- (BOOL) mailKeepDraftsAfterSend
{
  return [self boolForKey: @"SOGoMailKeepDraftsAfterSend"];
}

- (BOOL) mailAttachTextDocumentsInline
{
  return [self boolForKey: @"SOGoMailAttachTextDocumentsInline"];
}

- (NSArray *) mailListViewColumnsOrder
{
  return [self stringArrayForKey: @"SOGoMailListViewColumnsOrder"];
}

- (BOOL) mailCertificateEnabled
{
  return [self boolForKey: @"SOGoMailCertificateEnabled"];
}

- (NSArray *) superUsernames
{
  return [self stringArrayForKey: @"SOGoSuperUsernames"];
}

/* System-/Domain-/LDAP-level */

- (int) ldapQueryLimit
{
  return [self integerForKey: @"SOGoLDAPQueryLimit"];
}

- (int) ldapQueryTimeout
{
  return [self integerForKey: @"SOGoLDAPQueryTimeout"];
}

- (NSString *) ldapContactInfoAttribute
{
  return [self stringForKey: @"SOGoLDAPContactInfoAttribute"];
}

- (BOOL) ldapGroupExpansionEnabled
{
  return [self boolForKey: @"SOGoLDAPGroupExpansionEnabled"];
}

- (NSArray *) freeBusyDefaultInterval
{
  return [self arrayForKey: @"SOGoFreeBusyDefaultInterval"];
}

- (int) davCalendarStartTimeLimit
{
  return [self integerForKey: @"SOGoDAVCalendarStartTimeLimit"];
}

- (BOOL) iPhoneForceAllDayTransparency
{
  return [self boolForKey: @"SOGoiPhoneForceAllDayTransparency"];
}

/* overriden methods */
- (NSString *) language
{
  NSArray *browserLanguages, *supportedLanguages;
  NSString *language;
  WOContext *context;

  /* When we end up here, which means the active user has no language set, we
     fetch the list of languages that are accepted by his/her browser and we
     take the first of those which is supported. This ensures that the
     resulting languages is always available. If not, we fallback on the
     language of the domain or SOGo. */
  context = [[WOApplication application] context];
  browserLanguages = [[context request] browserLanguages];
  supportedLanguages = [[SOGoSystemDefaults sharedSystemDefaults]
                         supportedLanguages];
  language = [browserLanguages
               firstObjectCommonWithArray: supportedLanguages];
  if (!(language && [language isKindOfClass: [NSString class]]))
    language = [self stringForKey: @"SOGoLanguage"];

  return language;
}

- (NSArray *) additionalJSFiles
{
  return [self stringArrayForKey: @"SOGoUIAdditionalJSFiles"];
}

- (BOOL) hideSystemEMail
{
  return [self boolForKey: @"SOGoHideSystemEMail"];
}

- (int) searchMinimumWordLength
{
  return [self integerForKey: @"SOGoSearchMinimumWordLength"];
}

- (BOOL) notifyOnPersonalModifications
{
  return [self boolForKey: @"SOGoNotifyOnPersonalModifications"];
}

- (BOOL) notifyOnExternalModifications
{
  return [self boolForKey: @"SOGoNotifyOnExternalModifications"];
}

- (NSDictionary *) mailJunkSettings
{
  return [self objectForKey: @"SOGoMailJunkSettings"];
}

- (BOOL) createIdentitiesDisabled
{
  return [self boolForKey: @"SOGoCreateIdentitiesDisabled"];
}

- (NSString *) passwordRecoveryFrom
{
  NSString *emailFrom;

  emailFrom = [self stringForKey: @"SOGoPasswordRecoveryFrom"];

  if (!emailFrom)
    emailFrom = @"noreply@domain.com"; // Default email from when no domain set

  return emailFrom;
}

- (BOOL) forceRawHtmlSignature
{
  return [self objectForKey: @"SOGoForceRawHtmlSignature"] ? [self boolForKey: @"SOGoForceRawHtmlSignature"] : YES;
}

@end
